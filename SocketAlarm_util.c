int snprint_sockaddr(char *buffer, size_t buflen, struct sockaddr *addr) {
   char tmp[256];
   int port;
   if (addr->sa_family == AF_INET) {
      if (!inet_ntop(addr->sa_family, &((struct sockaddr_in*)addr)->sin_addr, tmp, sizeof(tmp)))
         snprintf(tmp, sizeof(tmp), "(invalid?)");
      port= ntohs(((struct sockaddr_in*)addr)->sin_port);
      return snprintf(buffer, buflen, "inet %s:%d", tmp, port);
   }
#ifdef AF_INET6
   else if (addr->sa_family == AF_INET6) {
      if (!inet_ntop(addr->sa_family, &((struct sockaddr_in6*)addr)->sin6_addr, tmp, sizeof(tmp)))
         snprintf(tmp, sizeof(tmp), "(invalid?)");
      port= ntohs(((struct sockaddr_in6*)addr)->sin6_port);
      return snprintf(buffer, buflen, "inet6 [%s]:%d", tmp, port);
   }
#endif
#ifdef AF_UNIX
   else if (addr->sa_family == AF_UNIX) {
      return snprintf(buffer, buflen, "unix %s", ((struct sockaddr_un*)addr)->sun_path);
   }
#endif
}

int parse_signal(SV *name_sv) {
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

int snprint_fd_table(char *buf, size_t sizeof_buf, int max_fd) {
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
