#ifndef M64_OSD_H
#define M64_OSD_H

int osd_printf(unsigned x, unsigned y, const char *fmt, ...);
void osd_invert(unsigned x, unsigned y, unsigned len);
void osd_clear(void);
void osd_flush(void);
void osd_enable(int enable);

#endif /* M64_OSD_H */
