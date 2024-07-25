#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"
#include "ppport.h"

#include <pthread.h>
#include <unistd.h>
#include <signal.h>
#include <stdlib.h>
#include <sys/types.h>
#include <sys/select.h>
#include <sys/stat.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <netinet/in.h>

#define AUTOCREATE 1
#define OR_DIE 2

#define CONTROL_TERMINATE 't'
#define CONTROL_CHANGE_FD 'c'

static pthread_t        watch_thread;
static int              control_pipe[2]= { -1, -1 };
static pthread_mutex_t  alarm_list_mutex= PTHREAD_MUTEX_INITIALIZER;
static volatile int     alarm_list_count= 0, alarm_list_alloc= 0;
static volatile struct socketalarm **alarm_list= NULL;

// May only be called by Perl's thread
static void alarm_list_add(struct socketalarm *alarm);
// May only be called by Perl's thread
static void alarm_list_remove(struct socketalarm *alarm);


#define EVENT_EOF   0x01
#define EVENT_EPIPE  0x02

#define ACT_KILL        1
#define ACT_CLOSE_FD    2
#define ACT_CLOSE_NAME  3
#define ACT_EXEC        4
#define ACT_RUN         5
#define ACT_SLEEP       6
#define ACT_REPEAT      7

struct action_kill {
   pid_t pid;
   int signal;
};
struct action_close_fd {
   int how;
   int fd;
};
struct action_close_name {
   int how;
   struct sockaddr *addr;
   socklen_t addr_len;
};
struct action_run {
   int argc;
   char **argv;   // allocated to length argc+1
};
struct action_sleep {
   double seconds;
   struct timespec end_ts; // used during execution
};
struct action_repeat {
   int count;
};
struct action {
   int op;
   union {
      struct action_kill       kill;
      struct action_close_fd   clfd;
      struct action_close_name clname;
      struct action_run        run;
      struct action_sleep      slp;
      struct action_repeat     rep;
   } act;
};

struct socketalarm {
   int list_ofs;     // position within action_list, initially -1 until activated
   int watch_fd;
   int event_mask;
   int action_count;
   int cur_action;   // used during execution
   HV *owner;
   struct action actions[];
};

static int parse_signal(SV *name);

bool parse_actions(AV *spec, struct action *actions, size_t *n_actions, char *aux_buf, size_t *aux_len) {
   bool success;
   size_t action_pos= 0;
   size_t aux_pos= 0;
   int i, n_spec= av_len(spec)+1;

   for (i= 0; i < n_spec; i++) {
      AV *action_spec;
      const char *act_name= NULL;
      STRLEN act_namelen= 0;
      SV **el;
      size_t n_el;

      // Get the arrayref for the next action
      el= av_fetch(spec, i, 0);
      if (!(el && *el && SvROK(*el) && SvTYPE(SvRV(*el)) == SVt_PVAV))
         croak("Actions must be arrayrefs");

      // Get the 'command' name of the action
      action_spec= (AV*) SvRV(*el);
      n_el= av_len(action_spec)+1;
      if (n_el < 1 || !(el= av_fetch(action_spec, 0, 0)) || !SvPOK(*el))
         croak("First element of action must be a string");
      act_name= SvPV(*el, act_namelen);

      // Dispatch based on the command
      switch (act_namelen) {
      case 3:
         if (strcmp(act_name, "sig") == 0) {
            int signal;
            if (n_el > 2)
               croak("Too many parameters for 'sig' action");
            signal= (n_el == 2 && (el= av_fetch(action_spec, 1, 0)) != NULL && SvOK(*el))?
               parse_signal(*el) : SIGALRM;
            // Is there an available action?
            if (action_pos < *n_actions) {
               actions[action_pos].op= ACT_KILL;
               actions[action_pos].act.kill.signal= signal;
               actions[action_pos].act.kill.pid= getpid();
            }
            ++action_pos;
            break;
         }
         if (strcmp(act_name, "run") == 0) {
            if (action_pos < *n_actions)
               actions[action_pos].op= ACT_RUN;
            goto parse_exec_common;
         }
      case 4:
         if (strcmp(act_name, "kill") == 0) {
            pid_t pid;
            int signal;
            if (n_el != 3)
               croak("Expected 2 parameters for 'kill' action");
            el= av_fetch(action_spec, 1, 0);
            if (!el || !SvIOK(*el))
               croak("Expected PID as first parameter to 'kill'");
            pid= SvIV(*el);
            el= av_fetch(action_spec, 2, 0);
            if (!el || !SvOK(*el))
               croak("Expected Signal as second parameter to 'kill'");
            signal= parse_signal(*el);
            if (action_pos < *n_actions) {
               actions[action_pos].op= ACT_KILL;
               actions[action_pos].act.kill.pid= pid;
               actions[action_pos].act.kill.signal= signal;
            }
            ++action_pos;
            break;
         }
         if (strcmp(act_name, "exec") == 0) {
            if (action_pos < *n_actions)
               actions[action_pos].op= ACT_EXEC;
            parse_exec_common: // arriving from 'run', above
            if (n_el < 2)
               croak("Expected at least one parameter for '%s'", act_name);
            // Align to pointer boundary within aux_buf
            aux_pos += sizeof(void*) - 1;
            aux_pos &= ~(sizeof(void*) - 1);
            {
               // allocate an array of char* within aux_buf
               char **argv= aux_pos + sizeof(void*) * n_el <= *aux_len? (char**)(aux_buf + aux_pos) : NULL;
               char *str;
               STRLEN len;
               int j, argc= n_el-1;
               aux_pos += sizeof(void*) * (argc+1);
               // size up each of the strings, and copy them to the buffer if space available
               for (j= 0; j < argc; j++) {
                  el= av_fetch(action_spec, j+1, 0);
                  if (!el || !*el || !SvOK(*el))
                     croak("Found undef element in arguments for '%s'", act_name);
                  str= SvPV(*el, len);
                  if (argv && aux_pos + len + 1 <= *aux_len) {
                     argv[j]= aux_buf + aux_pos;
                     memcpy(argv[j], str, len+1);
                  }
                  aux_pos += len+1;
               }
               // argv lists must end with NULL
               if (argv)
                  argv[argc]= NULL;
               // store in an action if space remaining.
               if (action_pos < *n_actions) {
                  actions[action_pos].act.run.argc= argc;
                  actions[action_pos].act.run.argv= argv;
               }
               ++action_pos;
            }
            break;
         }
      case 5:
         if (strcmp(act_name, "sleep") == 0) {
            if (n_el != 2)
               croak("Expected 1 parameter to 'sleep' action");
            el= av_fetch(action_spec, 1, 0);
            if (!el || !SvOK(*el) || !looks_like_number(*el))
               croak("Expected number of seconds in 'sleep' action");
            if (action_pos < *n_actions) {
               actions[action_pos].op= ACT_SLEEP;
               actions[action_pos].act.slp.seconds= SvNV(*el);
            }
            ++action_pos;
            break;
         }
      case 6:
         if (strcmp(act_name, "repeat") == 0) {
            croak("Unimplemented");
         }
      case 8:
         if (strcmp(act_name, "close_fd") == 0) {
            croak("Unimplemented");
         }
      default:
         croak("Unknown command '%s' in action list", act_name);
      }
   }
   success= (action_pos <= *n_actions) && (aux_pos <= *aux_len);
   *n_actions= action_pos;
   *aux_len= aux_pos;
   return success;
}

struct socketalarm *
socketalarm_new(int watch_fd, int event_mask, AV *action_spec) {
   size_t n_actions= 0, aux_len= 0, len_before_aux;
   struct socketalarm *self= NULL;

   parse_actions(action_spec, NULL, &n_actions, NULL, &aux_len);
   // buffer needs aligned to pointer, which sizeof(struct action) is not guaranteed to be
   len_before_aux= sizeof(struct socketalarm) + n_actions * sizeof(struct action);
   len_before_aux += sizeof(void*)-1;
   len_before_aux &= ~(sizeof(void*)-1);
   self= (struct socketalarm *) safecalloc(1, len_before_aux + aux_len);
   // second call should succeed, because we gave it back it's own requested buffer sizes.
   // could fail if user did something evil like a tied scalar that changes length...
   if (!parse_actions(action_spec, self->actions, &n_actions, ((char*)self) + len_before_aux, &aux_len))
      croak("BUG: buffers not large enough for parse_actions");
   self->watch_fd= watch_fd;
   self->event_mask= event_mask;
   self->action_count= n_actions;
   self->cur_action= -1;
   self->list_ofs= -1;
   self->owner= NULL;
   return self;
}

void socketalarm_free(struct socketalarm *sa) {
   // Must remove the socketalarm from the active list, if present
   if (sa->list_ofs >= 0)
      alarm_list_remove(sa);
   // was allocated as one chunk
   Safefree(sa);
}

static int parse_signal(SV *name_sv) {
   char *name;
   if (looks_like_number(name_sv))
      return SvIV(name_sv);
   name= SvPV_nolen(name_sv);
   if (!strcmp(name, "SIGKILL")) return SIGKILL;
   if (!strcmp(name, "SIGTERM")) return SIGTERM;
   if (!strcmp(name, "SIGUSR1")) return SIGUSR1;
   if (!strcmp(name, "SIGUSR2")) return SIGUSR2;
   if (!strcmp(name, "SIGALRM")) return SIGALRM;
   if (!strcmp(name, "SIGABRT")) return SIGABRT;
   if (!strcmp(name, "SIGINT" )) return SIGINT;
   if (!strcmp(name, "SIGHUP" )) return SIGHUP;
   croak("Unimplemented signal name %s", name);
}

// May only be called by Perl's thread
static void alarm_list_add(struct socketalarm *alarm) {
   if (!pthread_mutex_lock(&alarm_list_mutex))
      croak("mutex_lock failed");
   if (!alarm_list) {
      Newxz(alarm_list, 16, volatile struct socketalarm *);
      alarm_list_alloc= 16;
   }
   else if (alarm_list_count >= alarm_list_alloc) {
      Renew(alarm_list, alarm_list_alloc*2, volatile struct socketalarm *);
      alarm_list_alloc= alarm_list_alloc*2;
   }
   alarm->list_ofs= alarm_list_count;
   alarm_list[alarm_list_count++]= alarm;
   pthread_mutex_unlock(&alarm_list_mutex);
}

// May only be called by Perl's thread
static void alarm_list_remove(struct socketalarm *alarm) {
   int i= alarm->list_ofs;
   if (i >= 0) {
      if (!pthread_mutex_lock(&alarm_list_mutex))
         croak("mutex_lock failed");
      // fill the hole in the list by moving the final item
      if (i < alarm_list_count-1) {
         alarm_list[i]= alarm_list[alarm_list_count-1];
         alarm_list[i]->list_ofs= i;
      }
      --alarm_list_count;
      pthread_mutex_unlock(&alarm_list_mutex);
   }
}

int fileno_from_sv(SV *sv) {
   PerlIO *io;
   GV *gv;
   SV *rv;

   if (!SvOK(sv)) // undef
      return -1;

   if (!SvROK(sv)) // scalar, is it only digits?
      return looks_like_number(sv)? SvIV(sv) : -1;

   // is it a globref?
   rv= SvRV(sv);
   if (SvTYPE(rv) == SVt_PVGV) {
      io= IoIFP(GvIOp((GV*) rv));
      return PerlIO_fileno(io);
   }
   
   return -1;
}

int render_fd_table(char *buf, size_t sizeof_buf, int max_fd) {
   struct stat statbuf;
   struct sockaddr_storage addr;
   size_t len= 0;
   int i, j, n_closed;

   len= snprintf(buf, sizeof_buf, "File descriptors {\n");
   for (i= 0; i < max_fd; i++) {
      socklen_t addr_len= sizeof(addr);
      char * bufpos= buf + len;
      size_t avail= sizeof_buf > len? sizeof_buf - len : 0;

      if (fstat(i, &statbuf) < 0) {
         // Find the next valid fd
         for (j= i+1; j < max_fd; j++)
            if (fstat(j, &statbuf) == 0)
               break;
         if (j - i >= 2)
            len += snprintf(bufpos, avail, "%4d-%d: (closed)\n", i, j-1);
         else
            len += snprintf(bufpos, avail, "%4d: (closed)\n", i);
         i= j;
      }
      else if (!S_ISSOCK(statbuf.st_mode)) {
         char pathbuf[64];
         char linkbuf[256];
         int got;
         snprintf(pathbuf, sizeof(pathbuf), "/proc/%d/fd/%d", getpid(), i);
         pathbuf[sizeof(pathbuf)-1]= '\0';
         got= readlink(pathbuf, linkbuf, sizeof(linkbuf));
         if (got > 0 && got < sizeof(linkbuf)) {
            linkbuf[got]= '\0';
            len += snprintf(bufpos, avail, "%4d: %s\n", i, linkbuf);
         } else {
            len += snprintf(bufpos, avail, "%4d: (not a socket, no proc/fd?)\n", i);
         }
      }
      else {
         if (getsockname(i, (struct sockaddr*) &addr, &addr_len) < 0) {
            len += snprintf(bufpos, avail, "%4d: (getsockname failed)", i);
         }
         else if (addr.ss_family == AF_INET) {
            char addr_str[INET6_ADDRSTRLEN];
            struct sockaddr_in *sin= (struct sockaddr_in*) &addr;
            inet_ntop(AF_INET, &sin->sin_addr, addr_str, sizeof(addr_str));
            len += snprintf(bufpos, avail, "%4d: inet [%s]:%d", i, addr_str, ntohs(sin->sin_port));
         }
         else if (addr.ss_family == AF_UNIX) {
            struct sockaddr_un *sun= (struct sockaddr_un*) &addr;
            char *p;
            // sanitize socket name, which will be random bytes if anonymous
            for (p= sun->sun_path; *p; p++)
               if (*p <= 0x20 || *p >= 0x7F)
                  *p= '?';
            len += snprintf(bufpos, avail, "%4d: unix [%s]", i, sun->sun_path);
         }
         else {
            len += snprintf(bufpos, avail, "%4d: ? socket family %d", i, addr.ss_family);
         }
         bufpos= buf + len;
         avail= sizeof_buf > len? sizeof_buf - len : 0;

         // Is it connected to anything?
         if (getpeername(i, (struct sockaddr*) &addr, &addr_len) == 0) {
            if (addr.ss_family == AF_INET) {
               char addr_str[INET6_ADDRSTRLEN];
               struct sockaddr_in *sin= (struct sockaddr_in*) &addr;
               inet_ntop(AF_INET, &sin->sin_addr, addr_str, sizeof(addr_str));
               len += snprintf(bufpos, avail, " -> [%s]:%d\n", addr_str, ntohs(sin->sin_port));
            }
            else if (addr.ss_family == AF_UNIX) {
               struct sockaddr_un *sun= (struct sockaddr_un*) &addr;
               char *p;
               // sanitize socket name, which will be random bytes if anonymous
               for (p= sun->sun_path; *p; p++)
                  if (*p <= 0x20 || *p >= 0x7F)
                     *p= '?';
               len += snprintf(bufpos, avail, " -> unix [%s]\n", sun->sun_path);
            }
            else {
               len += snprintf(bufpos, avail, " -> socket family %d\n", addr.ss_family);
            }
         }
         else {
            len++;
            if (avail > 0)
               bufpos[0]= '\n';
         }
      }
   }
   // Did it all fit in the buffer, including NUL terminator?
   if (len + 3 <= sizeof_buf) {
      buf[len++]= '}';
      buf[len++]= '\n';
      buf[len  ]= '\0';
   }
   else { // overwrite last 2 chars to end with newline and NUL
      if (sizeof_buf > 1) buf[sizeof_buf-2]= '\n';
      if (sizeof_buf > 0) buf[sizeof_buf-1]= '\0';
      len= sizeof_buf-1;
   }
   return len;
}

/*------------------------------------------------------------------------------------
 * Definitions of Perl MAGIC that attach C structs to Perl SVs
 */

// destructor for Watch objects
static int iosa_socketalarm_magic_free(pTHX_ SV* sv, MAGIC* mg) {
   if (mg->mg_ptr) {
      socketalarm_free((struct socketalarm*) mg->mg_ptr);
      mg->mg_ptr= NULL;
   }
   return 0; // ignored anyway
}
#ifdef USE_ITHREADS
static int iosa_magic_socketalarm_dup(pTHX_ MAGIC *mg, CLONE_PARAMS *param) {
   croak("This object cannot be shared between threads");
   return 0;
};
#else
#define iosa_socketalarm_magic_dup 0
#endif

// magic table for Watch objects
static MGVTBL iosa_socketalarm_magic_vt= {
   0, /* get */
   0, /* write */
   0, /* length */
   0, /* clear */
   iosa_socketalarm_magic_free,
   0, /* copy */
   iosa_socketalarm_magic_dup
#ifdef MGf_LOCAL
   ,0
#endif
};

// Return the socketalarm that was attached to a perl Watch object via MAGIC.
// The 'obj' should be a reference to a blessed magical SV.
static struct socketalarm* get_magic_socketalarm(SV *obj, int flags) {
   SV *sv;
   MAGIC* magic;

   if (!sv_isobject(obj)) {
      if (flags & OR_DIE)
         croak("Not an object");
      return NULL;
   }
   sv= SvRV(obj);
   if (SvMAGICAL(sv)) {
      /* Iterate magic attached to this scalar, looking for one with our vtable */
      if ((magic= mg_findext(sv, PERL_MAGIC_ext, &iosa_socketalarm_magic_vt)))
         /* If found, the mg_ptr points to the fields structure. */
         return (struct socketalarm*) magic->mg_ptr;
   }
   if (flags & OR_DIE)
      croak("Object lacks 'struct TreeRBXS_item' magic");
   return NULL;
}

// Return existing Watch object, or create a new one.
// Returned SV has a non-mortal refcount, which is what the typemap
// wants for returning a "struct socketalarm*" to perl-land
static SV* wrap_socketalarm(struct socketalarm *sa) {
   SV *obj;
   MAGIC *magic;
   // Since this is used in typemap, handle NULL gracefully
   if (!sa)
      return &PL_sv_undef;
   // If there is already a node object, return a new reference to it.
   if (sa->owner)
      return newRV_inc((SV*) sa->owner);
   // else create a node object
   sa->owner= newHV();
   obj= newRV_noinc((SV*) sa->owner);
   sv_bless(obj, gv_stashpv("IO::SocketAlarm", GV_ADD));
   magic= sv_magicext((SV*) sa->owner, NULL, PERL_MAGIC_ext, &iosa_socketalarm_magic_vt, (const char*) sa, 0);
#ifdef USE_ITHREADS
   magic->mg_flags |= MGf_DUP;
#else
   (void)magic; // suppress 'unused' warning
#endif
   return obj;
}

#define EXPORT_ENUM(x) newCONSTSUB(stash, #x, new_enum_dualvar(aTHX_ x, newSVpvs_share(#x)))
static SV * new_enum_dualvar(pTHX_ IV ival, SV *name) {
   SvUPGRADE(name, SVt_PVNV);
   SvIV_set(name, ival);
   SvIOK_on(name);
   SvREADONLY_on(name);
   return name;
}

MODULE = IO::SocketAlarm               PACKAGE = IO::SocketAlarm

struct socketalarm *
_new_socketalarm(sock_sv, eventmask, actions)
   SV *sock_sv
   int eventmask
   AV *actions
   INIT:
      int sock_fd= fileno_from_sv(sock_sv);
      struct stat statbuf;
   CODE:
      if (!(sock_fd >= 0 && fstat(sock_fd, &statbuf) == 0 && S_ISSOCK(statbuf.st_mode)))
         croak("Not an open socket");
      RETVAL= socketalarm_new(sock_fd, eventmask, actions);
   OUTPUT:
      RETVAL

void
_terminate_all()
   PPCODE:
      (void)0;

MODULE = IO::SocketAlarm               PACKAGE = IO::SocketAlarm::Util

bool
is_socket(fd_sv)
   SV *fd_sv
   INIT:
      int fd= fileno_from_sv(fd_sv);
      struct stat statbuf;
   CODE:
      RETVAL= fd >= 0 && fstat(fd, &statbuf) == 0 && S_ISSOCK(statbuf.st_mode);
   OUTPUT:
      RETVAL

SV *
render_fd_table(max_fd=1024)
   int max_fd
   INIT:
      SV *out= newSVpvn("",0);
      size_t avail= 0, needed= 1023;
   CODE:
      // FD status could change between calls, changing the length requirement, so loop.
      // 'avail' count includes the NUL byte, and 'needed' does not.
      while (avail <= needed) {
         sv_grow(out, needed+1);
         avail= needed+1;
         needed= render_fd_table(SvPVX(out), avail, max_fd);
      }
      SvCUR_set(out, needed);
      RETVAL= out;
   OUTPUT:
      RETVAL

#-----------------------------------------------------------------------------
#  Constants
#

BOOT:
   HV* stash= gv_stashpvn("IO::SocketAlarm::Util", 21, 1);
   EXPORT_ENUM(EVENT_EOF);
   EXPORT_ENUM(EVENT_EPIPE);

PROTOTYPES: DISABLE
