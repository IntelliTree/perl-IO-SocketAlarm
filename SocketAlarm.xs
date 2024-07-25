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

#define EVENT_EOF   0x01
#define EVENT_EPIPE  0x02

static pthread_t watch_thread;

static int control_pipe[2]= { -1, -1 };

struct socketalarm {
   HV *owner;
   int watch_fd;
   int mysql_sock;
   int signal;
   #define MAX_EXEC_ARGC 64
   int exec_argc;
   int exec_arg_ofs[MAX_EXEC_ARGC];
   char exec_buffer[512];
};

pthread_mutex_t action_data_mutex= PTHREAD_MUTEX_INITIALIZER;
static volatile int watch_count;
static volatile struct socketalarm **watches;

int _fileno_from_sv(SV *sv) {
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

int _render_fd_table(char *buf, size_t sizeof_buf, int max_fd) {
   struct stat statbuf;
   struct sockaddr_storage addr;
   socklen_t addr_len;
   char *bufpos= buf, *buflim= buf + sizeof_buf;
   int i, j, n_closed;

   bufpos += snprintf(bufpos, buflim - bufpos, "File descriptors {\n");
   for (i= 0; i < max_fd && bufpos < buflim; i++) {
      addr_len= sizeof(addr);
      if (fstat(i, &statbuf) < 0) {
         // Find the next valid fd
         for (j= i+1; j < max_fd; j++)
            if (fstat(j, &statbuf) == 0)
               break;
         if (j - i >= 2)
            bufpos += snprintf(bufpos, buflim - bufpos, "%4d-%d: (closed)\n", i, j-1);
         else
            bufpos += snprintf(bufpos, buflim - bufpos, "%4d: (closed)\n", i);
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
            bufpos += snprintf(bufpos, buflim - bufpos, "%4d: %s\n", i, linkbuf);
         } else {
            bufpos += snprintf(bufpos, buflim - bufpos, "%4d: (not a socket, no proc/fd?)\n", i);
         }
      }
      else {
         if (getsockname(i, (struct sockaddr*) &addr, &addr_len) < 0) {
            bufpos += snprintf(bufpos, buflim - bufpos, "%4d: (getsockname failed)", i);
         }
         else if (addr.ss_family == AF_INET) {
            char addr_str[INET6_ADDRSTRLEN];
            struct sockaddr_in *sin= (struct sockaddr_in*) &addr;
            inet_ntop(AF_INET, &sin->sin_addr, addr_str, sizeof(addr_str));
            bufpos += snprintf(bufpos, buflim - bufpos, "%4d: inet [%s]:%d", i, addr_str, ntohs(sin->sin_port));
         }
         else if (addr.ss_family == AF_UNIX) {
            struct sockaddr_un *sun= (struct sockaddr_un*) &addr;
            char *p;
            // sanitize socket name, which will be random bytes if anonymous
            for (p= sun->sun_path; *p; p++)
               if (*p <= 0x20 || *p >= 0x7F)
                  *p= '?';
            bufpos += snprintf(bufpos, buflim - bufpos, "%4d: unix [%s]", i, sun->sun_path);
         }
         else {
            bufpos += snprintf(bufpos, buflim - bufpos, "%4d: ? socket family %d", i, addr.ss_family);
         }

         // Is it connected to anything?
         if (bufpos < buflim && getpeername(i, (struct sockaddr*) &addr, &addr_len) == 0) {
            if (addr.ss_family == AF_INET) {
               char addr_str[INET6_ADDRSTRLEN];
               struct sockaddr_in *sin= (struct sockaddr_in*) &addr;
               inet_ntop(AF_INET, &sin->sin_addr, addr_str, sizeof(addr_str));
               bufpos += snprintf(bufpos, buflim - bufpos, " -> [%s]:%d\n", addr_str, ntohs(sin->sin_port));
            }
            else if (addr.ss_family == AF_UNIX) {
               struct sockaddr_un *sun= (struct sockaddr_un*) &addr;
               char *p;
               // sanitize socket name, which will be random bytes if anonymous
               for (p= sun->sun_path; *p; p++)
                  if (*p <= 0x20 || *p >= 0x7F)
                     *p= '?';
               bufpos += snprintf(bufpos, buflim - bufpos, " -> unix [%s]\n", sun->sun_path);
            }
            else {
               bufpos += snprintf(bufpos, buflim - bufpos, " -> socket family %d\n", addr.ss_family);
            }
         }
         else if (bufpos + 1 < buflim) {
            *bufpos++ = '\n';
            *bufpos= '\0';
         }
      }
   }
   if (bufpos + 2 < buflim) {
      bufpos += snprintf(bufpos, buflim - bufpos, "}\n");
   } else {
      if (sizeof_buf >= 3) buflim[-3]= '}';
      if (sizeof_buf >= 2) buflim[-2]= '\n';
      if (sizeof_buf >= 1) buflim[-1]= '\0';
      bufpos= buflim;
   }
   return bufpos - buf;
}

void iosa_socketalarm_destroy(struct socketalarm *sw) {
   // TODO
}

/*------------------------------------------------------------------------------------
 * Definitions of Perl MAGIC that attach C structs to Perl SVs
 */

// destructor for Watch objects
static int iosa_socketalarm_magic_free(pTHX_ SV* sv, MAGIC* mg) {
   if (mg->mg_ptr) {
      iosa_socketalarm_destroy((struct socketalarm*) mg->mg_ptr);
      Safefree(mg->mg_ptr);
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
static struct socketalarm* iosa_get_magic_socketalarm(SV *obj, int flags) {
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
static SV* iosa_wrap_socketalarm(struct socketalarm *sw) {
   SV *obj;
   MAGIC *magic;
   // Since this is used in typemap, handle NULL gracefully
   if (!sw)
      return &PL_sv_undef;
   // If there is already a node object, return a new reference to it.
   if (sw->owner)
      return newRV_inc((SV*) sw->owner);
   // else create a node object
   sw->owner= newHV();
   obj= newRV_noinc((SV*) sw->owner);
   sv_bless(obj, gv_stashpv("IO::SocketStatusSignaler::Watch", GV_ADD));
   magic= sv_magicext((SV*) sw->owner, NULL, PERL_MAGIC_ext, &iosa_socketalarm_magic_vt, (const char*) sw, 0);
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

void
_terminate_all()
   PPCODE:
      (void)0;

MODULE = IO::SocketAlarm               PACKAGE = IO::SocketAlarm::Util

SV *
render_fd_table(max_fd=1024)
   int max_fd
   INIT:
      char buffer[4096];
   CODE:
      int len= _render_fd_table(buffer, sizeof(buffer), max_fd);
      RETVAL= newSVpvn(buffer, len);
   OUTPUT:
      RETVAL

bool
is_socket(fd_sv)
   SV *fd_sv
   INIT:
      int fd= _fileno_from_sv(fd_sv);
      struct stat statbuf;
   CODE:
      RETVAL= fd >= 0 && fstat(fd, &statbuf) == 0 && S_ISSOCK(statbuf.st_mode);
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
