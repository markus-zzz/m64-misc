#ifndef M64_MENU_H__
#define M64_MENU_H__

#include "osd.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifndef MAX
#define MAX(a, b) ((a) > (b) ? (a) : (b))
#endif

typedef struct MenuItem {
  struct MenuItem *prev;
  struct MenuItem *next;
  const char *str;
  void (*action)(struct MenuItem *item, void *opaque);
  void *opaque;
  const char **opt_list; // Null terminated list of options
  unsigned opt_idx;
} MenuItem_t;

typedef struct Menu {
  struct Menu *parent;
  struct MenuItem *first_item;
  struct MenuItem *last_item;
  struct MenuItem *curr_item;
  const char *title;
} Menu_t;

Menu_t *menu_create(Menu_t *parent, const char *title);

MenuItem_t *menu_item_create(Menu_t *menu, const char *str);

void menu_item_set_action(MenuItem_t *item, void (*action)(struct MenuItem *item, void *opaque),
                          void *opaque);

void menu_item_print(const MenuItem_t *item, char *buf, size_t size);

void menu_draw();

void menu_input_up();
void menu_input_down();
void menu_input_select();
void menu_input_back();

void menu_action_jump_menu(struct MenuItem *item, void *opaque);

#endif
