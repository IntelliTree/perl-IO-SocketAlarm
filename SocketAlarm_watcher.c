#include "pollfd_rbhash.c"

// Returns false when time to exit
static bool do_watch();

#define WATCHTHREAD_DEBUG(fmt, ...) (void) write(2, msgbuf, snprintf(msgbuf, sizeof(msgbuf), fmt, ##__VA_ARGS__ ))
#define WATCHTHREAD_WARN(fmt, ...) (void) write(2, msgbuf, snprintf(msgbuf, sizeof(msgbuf), fmt, ##__VA_ARGS__ ))

void* watch_thread_main(void* unused) {
   while (do_watch()) {}
   return NULL;
}

// separate from watch_thread_main because it uses a dynamic alloca() on each iteration
bool do_watch() {
   struct pollfd *pollset;
   struct timespec wake_time= { 0, -1 };
   int capacity, buckets, sz, n_poll, ofs, i, j, n, delay= 10000;
   char msgbuf[128];
   
   if (pthread_mutex_lock(&watch_list_mutex))
      abort(); // should never fail
   // allocate to the size of watch_list_count, but cap it at 1024 for sanity
   // since this is coming off the stack.  If any user actually wants to watch
   // more than 1024 sockets, this needs re-designed, but I'm not sure if
   // malloc is thread-safe when the main perl binary was compiled without
   // thread support.
   capacity= watch_list_count > 1024? 1024 : watch_list_count+1;
   buckets= capacity < 16? 16 : capacity < 128? 32 : 64;
   sz= sizeof(struct pollfd) * capacity + POLLFD_RBHASH_SIZEOF(capacity, buckets);
   pollset= (struct pollfd *) alloca(sz);
   memset(pollset, 0, sz);
   
   // first fd is always our control socket
   pollset[0].fd= control_pipe[0];
   pollset[0].events= POLLIN;
   n_poll= 1;
   WATCHTHREAD_DEBUG("watch_thread loop iter, watch_list_count=%d capacity=%d buckets=%d\n", watch_list_count, capacity, buckets);
   for (i= 0, n= watch_list_count; i < n && n_poll < capacity; i++) {
      struct socketalarm *alarm= watch_list[i];
      int fd= alarm->watch_fd;
      // Ignore watches that finished.  Main thread needs to clean these up.
      if (alarm->cur_action >= alarm->action_count)
         continue;
      ofs= -1 + (int)pollfd_rbhash_insert(pollset+capacity, capacity, n_poll+1, fd & (buckets-1), fd);
      if (ofs < 0) { // corrupt datastruct, should never happen
         WATCHTHREAD_WARN("BUG: corrupt pollfd_rbhash");
         break;
      }
      if (ofs == n_poll) { // using the new uninitialized one?
         pollset[ofs].fd= fd;
         pollset[ofs].events= 0;
         ++n_poll;
      }
      // Add the poll flags of this socketalarm
      int events= alarm->event_mask;
      if (events & EVENT_EOF)
         pollset[ofs].events |= POLLIN;
      // If the socketalarm is in the process of being executed and stopped at
      // a 'sleep' command, factor that into the wake time.
      if (alarm->wake_ts.tv_nsec != -1) {
         if (wake_time.tv_nsec == -1
          || wake_time.tv_sec > alarm->wake_ts.tv_sec
          || (wake_time.tv_sec == alarm->wake_ts.tv_sec && wake_time.tv_nsec > alarm->wake_ts.tv_nsec)
         ) {
            wake_time.tv_sec= alarm->wake_ts.tv_sec;
            wake_time.tv_nsec= alarm->wake_ts.tv_nsec;
         }
      }
   }
   pthread_mutex_unlock(&watch_list_mutex);

   // If there is a defined wake-time, truncate the delay if the wake-time comes first
   if (wake_time.tv_nsec != -1) {
      struct timespec now_ts= { 0, -1 };
      if (lazy_build_now_ts(&now_ts)) {
         // subtract to find out delay. poll only has millisecond precision anyway.
         int wake_delay= ((long)wake_time.tv_sec - (long)now_ts.tv_sec) * 1000
            + (wake_time.tv_nsec - now_ts.tv_nsec)/1000000;
         if (wake_delay < delay)
            delay= wake_delay;
      }
   }
   WATCHTHREAD_DEBUG("poll(n=%d delay=%d)\n", n_poll, delay);
   if (poll(pollset, n_poll, delay < 0? 0 : delay) < 0) {
      perror("poll");
      return false;
   }
   for (i= 0; i < n_poll; i++) {
      WATCHTHREAD_DEBUG("  fd=%3d revents=%02X\n", pollset[i].fd, pollset[i].revents);
   }
   
   // First, did we get new control messages?
   if (pollset[0].revents & POLLIN) {
      char msg;
      if (read(pollset[0].fd, &msg, 1) != 1) { // should never fail
         WATCHTHREAD_DEBUG("read != 1\n");
         return false;
      }
      if (msg == CONTROL_TERMINATE) {// intentional exit
         WATCHTHREAD_DEBUG("terminate received\n");
         return false;
      }
      // else its CONTROL_REWATCH, which means we should start over with new alarms to watch
      WATCHTHREAD_DEBUG("got REWATCH, starting over\n");
      return true;
   }
   
   // Now, process all of the socketalarms using the statuses from the pollfd
   if (pthread_mutex_lock(&watch_list_mutex))
      abort(); // should never fail
   for (i= 0, n= watch_list_count; i < n; i++) {
      struct socketalarm *alarm= watch_list[i];
      int fd= alarm->watch_fd, poll_idx;
      if (alarm->cur_action >= alarm->action_count) // stale alarm left in list
         continue;

      poll_idx= -1 + (int)pollfd_rbhash_find(pollset+capacity, capacity, fd & (buckets-1), fd);
      if (poll_idx < 0) // can only happen if watch_list changed while we let go of the mutex (or a bug in rbhash)
         continue;

      // If it has not been triggered yet, see if it is now
      if (alarm->cur_action == -1) {
         bool trigger= false;
         int events= alarm->event_mask;
         if (events & EVENT_EOF) {
            if (pollset[poll_idx].revents & POLLHUP)
               trigger= true;
            else if (pollset[poll_idx].revents & POLLIN)
               trigger= true;
            //}
         }
         if (trigger)
            socketalarm_exec_actions(alarm);
      }
      else
         socketalarm_exec_actions(alarm);
   }
   pthread_mutex_unlock(&watch_list_mutex);
   return true;
}

// May only be called by Perl's thread
static bool watch_list_add(struct socketalarm *alarm) {
   int i;
   if (pthread_mutex_lock(&watch_list_mutex))
      croak("mutex_lock failed");

   if (!watch_list) {
      Newxz(watch_list, 16, struct socketalarm * volatile);
      watch_list_alloc= 16;
   }
   else {
      // Clean up completed watches
      for (i= watch_list_count-1; i >= 0; --i) {
         if (watch_list[i]->cur_action >= watch_list[i]->action_count) {
            watch_list[i]->list_ofs= -1;
            if (--watch_list_count > i) {
               watch_list[i]= watch_list[watch_list_count];
               watch_list[i]->list_ofs= i;
            }
            watch_list[watch_list_count]= NULL;
         }
      }
      // allocate more if needed
      if (watch_list_count >= watch_list_alloc) {
         Renew(watch_list, watch_list_alloc*2, struct socketalarm * volatile);
         watch_list_alloc= watch_list_alloc*2;
      }
   }

   i= alarm->list_ofs;
   if (i < 0) { // only add if not already added
      alarm->list_ofs= watch_list_count;
      watch_list[watch_list_count++]= alarm;
      // Initialize fields that watcher uses to track status
      alarm->cur_action= -1;
      alarm->wake_ts.tv_nsec= -1;
   }
   
   // If the thread is not running, start it.  Also create pipe if needed.
   if (control_pipe[1] < 0) {
      if (pipe(control_pipe) != 0) {
         pthread_mutex_unlock(&watch_list_mutex);
         croak("pipe() failed");
      }

      if (pthread_create(&watch_thread, NULL, (void*(*)(void*)) watch_thread_main, NULL) != 0) {
         pthread_mutex_unlock(&watch_list_mutex);
         croak("pthread_create failed");
      }
   } else {
      char msg= CONTROL_REWATCH;
      if (write(control_pipe[1], &msg, 1) != 1) {
         pthread_mutex_unlock(&watch_list_mutex);
         croak("failed to notify watch_thread");
      }
   }
   pthread_mutex_unlock(&watch_list_mutex);
   return i < 0;
}

// May only be called by Perl's thread
static bool watch_list_remove(struct socketalarm *alarm) {
   int i;
   if (pthread_mutex_lock(&watch_list_mutex))
      croak("mutex_lock failed");
   // Clean up completed watches
   for (i= watch_list_count-1; i >= 0; --i) {
      if (watch_list[i]->cur_action >= watch_list[i]->action_count) {
         watch_list[i]->list_ofs= -1;
         if (--watch_list_count > i) {
            watch_list[i]= watch_list[watch_list_count];
            watch_list[i]->list_ofs= i;
         }
         watch_list[watch_list_count]= NULL;
      }
   }
   i= alarm->list_ofs;
   if (i >= 0) {
      // fill the hole in the list by moving the final item
      if (i < watch_list_count-1) {
         watch_list[i]= watch_list[watch_list_count-1];
         watch_list[i]->list_ofs= i;
      }
      --watch_list_count;
      alarm->list_ofs= -1;

      // This one was still an active watch, so need to notify thread
      //  not to listen for it anymore
      if (control_pipe[1] >= 0) {
         char msg= CONTROL_REWATCH;
         if (write(control_pipe[1], &msg, 1) != 1) {
            pthread_mutex_unlock(&watch_list_mutex);
            croak("failed to notify watch_thread");
         }
      }
   }
   pthread_mutex_unlock(&watch_list_mutex);
   return i >= 0;
}

// only called during Perl's END phase.  Just need to let
// things end gracefully and not have the thread go nuts
// as sockets get closed.
static void shutdown_watch_thread() {
   int i;
   // Wipe the alarm list
   if (pthread_mutex_lock(&watch_list_mutex))
      croak("mutex_lock failed");
   for (i= 0; i < watch_list_count; i++) {
      watch_list[i]->list_ofs= -1;
      watch_list[i]= NULL;
   }
   watch_list_count= 0;

   // Notify the thread to stop
   if (control_pipe[1] >= 0) {
      char msg= CONTROL_TERMINATE;
      if (write(control_pipe[1], &msg, 1) != 1)
         warn("write(control_pipe) failed");
   }
   
   pthread_mutex_unlock(&watch_list_mutex);
   // don't bother unallocating watch_list or closing pipe,
   // because we're exiting anyway.
}
