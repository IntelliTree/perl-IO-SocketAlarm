#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"
#include "ppport.h"

#include <pthread.h>
#include <unistd.h>
#include <signal.h>
#include <stdlib.h>
#include <sys/types.h>
#include <poll.h>
#include <sys/stat.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <netinet/in.h>

#define AUTOCREATE 1
#define OR_DIE 2

struct socketalarm;

#include "SocketAlarm_util.h"
#include "SocketAlarm_action.h"
#include "pollfd_rbhash.h"
#include "SocketAlarm_watcher.h"

#define EVENT_EOF    0x01
#define EVENT_EPIPE  0x02

struct socketalarm {
   int list_ofs;     // position within action_list, initially -1 until activated
   int watch_fd;
   int event_mask;
   int action_count;
   int cur_action;          // used during execution
   struct timespec wake_ts; // used during execution
   HV *owner;
   struct action actions[];
};

static void socketalarm_exec_actions(struct socketalarm *sa);

#include "SocketAlarm_util.c"
#include "SocketAlarm_action.c"
#include "SocketAlarm_watcher.c"

struct socketalarm *
socketalarm_new(int watch_fd, int event_mask, SV **action_spec, size_t spec_count) {
   size_t n_actions= 0, aux_len= 0, len_before_aux;
   struct socketalarm *self= NULL;

   parse_actions(action_spec, spec_count, NULL, &n_actions, NULL, &aux_len);
   // buffer needs aligned to pointer, which sizeof(struct action) is not guaranteed to be
   len_before_aux= sizeof(struct socketalarm) + n_actions * sizeof(struct action);
   len_before_aux += sizeof(void*)-1;
   len_before_aux &= ~(sizeof(void*)-1);
   self= (struct socketalarm *) safecalloc(1, len_before_aux + aux_len);
   // second call should succeed, because we gave it back it's own requested buffer sizes.
   // could fail if user did something evil like a tied scalar that changes length...
   if (!parse_actions(action_spec, spec_count, self->actions, &n_actions, ((char*)self) + len_before_aux, &aux_len))
      croak("BUG: buffers not large enough for parse_actions");
   self->watch_fd= watch_fd;
   self->event_mask= event_mask;
   self->action_count= n_actions;
   self->list_ofs= -1; // initially not in the watch list
   self->owner= NULL;
   return self;
}

void socketalarm_exec_actions(struct socketalarm *sa) {
   bool resume= sa->cur_action >= 0;
   struct timespec now_ts= { 0, -1 };
   if (!resume)
      sa->cur_action= 0;
   while (sa->cur_action < sa->action_count) {
      if (!execute_action(sa->actions + sa->cur_action, resume, &now_ts, sa))
         break;
      resume= false;
      ++sa->cur_action;
   }
}

void socketalarm_free(struct socketalarm *sa) {
   // Must remove the socketalarm from the active list, if present
   watch_list_remove(sa);
   // was allocated as one chunk
   Safefree(sa);
}

/*------------------------------------------------------------------------------------
 * Definitions of Perl MAGIC that attach C structs to Perl SVs
 */

// destructor for Watch objects
static int socketalarm_magic_free(pTHX_ SV* sv, MAGIC* mg) {
   if (mg->mg_ptr) {
      socketalarm_free((struct socketalarm*) mg->mg_ptr);
      mg->mg_ptr= NULL;
   }
   return 0; // ignored anyway
}
#ifdef USE_ITHREADS
static int socketalarm_magic_dup(pTHX_ MAGIC *mg, CLONE_PARAMS *param) {
   croak("This object cannot be shared between threads");
   return 0;
};
#else
#define socketalarm_magic_dup 0
#endif

// magic table for Watch objects
static MGVTBL socketalarm_magic_vt= {
   0, /* get */
   0, /* write */
   0, /* length */
   0, /* clear */
   socketalarm_magic_free,
   0, /* copy */
   socketalarm_magic_dup
#ifdef MGf_LOCAL
   ,0
#endif
};

// Return the socketalarm that was attached to a perl Watch object via MAGIC.
// The 'obj' should be a reference to a blessed magical SV.
static struct socketalarm*
get_magic_socketalarm(SV *obj, int flags) {
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
      if ((magic= mg_findext(sv, PERL_MAGIC_ext, &socketalarm_magic_vt)))
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
   magic= sv_magicext((SV*) sa->owner, NULL, PERL_MAGIC_ext, &socketalarm_magic_vt, (const char*) sa, 0);
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
      SV **action_list= NULL;
      size_t n_actions= 0;
   CODE:
      if (!(sock_fd >= 0 && fstat(sock_fd, &statbuf) == 0 && S_ISSOCK(statbuf.st_mode)))
         croak("Not an open socket");
      if (actions != NULL) {
         n_actions= av_count(actions);
         action_list= AvARRAY(actions);
      }
      RETVAL= socketalarm_new(sock_fd, eventmask, action_list, n_actions);
   OUTPUT:
      RETVAL

bool
start(alarm)
   struct socketalarm *alarm
   CODE:
      RETVAL= watch_list_add(alarm);
   OUTPUT:
      RETVAL

bool
cancel(alarm)
   struct socketalarm *alarm
   CODE:
      RETVAL= watch_list_remove(alarm);
   OUTPUT:
      RETVAL

SV*
stringify(alarm)
   struct socketalarm *alarm
   INIT:
      SV *out= sv_2mortal(newSVpvn("",0));
      int i;
   CODE:
      sv_catpvf(out, "watch fd: %d\n", alarm->watch_fd);
      sv_catpvf(out, "event mask:%s%s\n",
         alarm->event_mask & EVENT_EOF? " EOF":"",
         alarm->event_mask & EVENT_EPIPE? " EPIPE":""
      );
      sv_catpv(out, "actions:\n");
      for (i= 0; i < alarm->action_count; i++) {
         char buf[256];
         snprint_action(buf, sizeof(buf), alarm->actions+i);
         sv_catpvf(out, "%4d: %s\n", i, buf);
      }
      SvREFCNT_inc(out);
      RETVAL= out;
   OUTPUT:
      RETVAL

void
_terminate_all()
   PPCODE:
      shutdown_watch_thread();

MODULE = IO::SocketAlarm               PACKAGE = IO::SocketAlarm::Util

struct socketalarm *
socketalarm(sock_sv, ...)
   SV *sock_sv
   INIT:
      int sock_fd= fileno_from_sv(sock_sv);
      int eventmask= EVENT_EOF|EVENT_EPIPE;
      int action_ofs= 1;
      struct stat statbuf;
   CODE:
      if (!(sock_fd >= 0 && fstat(sock_fd, &statbuf) == 0 && S_ISSOCK(statbuf.st_mode)))
         croak("Not an open socket");
      if (items > 1) {
         // must either be a scalar, a scalar followed by actions specs, or action specs
         if (SvOK(ST(1)) && looks_like_number(ST(1))) {
            eventmask= SvIV(ST(1));
            action_ofs++;
         }
      }
      RETVAL= socketalarm_new(sock_fd, eventmask, &(ST(action_ofs)), items - action_ofs);
   OUTPUT:
      RETVAL

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
get_fd_table_str(max_fd=1024)
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
         needed= snprint_fd_table(SvPVX(out), avail, max_fd);
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
