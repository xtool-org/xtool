#ifndef CINOTIFY_SHIMS_H
#define CINOTIFY_SHIMS_H

#ifdef __linux__

#include <stdio.h>
#include <stdint.h>
#include <sys/inotify.h>

static inline const char *cin_event_name(const struct inotify_event *event) {
	if (event->len)
		return event->name;
	else
		return NULL;
}

static const uint32_t cin_all_events = IN_ALL_EVENTS;

#endif

#endif /* CINOTIFY_SHIMS_H */
