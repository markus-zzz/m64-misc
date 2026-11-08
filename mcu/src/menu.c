#include "menu.h"
#include "osd.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static Menu_t *curr_menu = NULL;

Menu_t *menu_create(Menu_t *parent, const char *title) {
  Menu_t *menu = (Menu_t *)calloc(1, sizeof(Menu_t));
  menu->title = title;
  menu->parent = parent;
  if (!parent)
    curr_menu = menu;

  return menu;
}

MenuItem_t *menu_item_create(Menu_t *menu, const char *str) {
  MenuItem_t *item = (MenuItem_t *)calloc(1, sizeof(MenuItem_t));
  item->str = str;

  if (menu->first_item == NULL) {
    menu->first_item = item;
    menu->curr_item = item;
  }
  item->prev = menu->last_item;
  if (menu->last_item != NULL) {
    menu->last_item->next = item;
  }
  menu->last_item = item;

  return item;
}

void menu_item_set_action(MenuItem_t *item, void (*action)(struct MenuItem *item, void *opaque),
                          void *opaque) {
  item->action = action;
  item->opaque = opaque;
}

void menu_item_print(const MenuItem_t *item, char *buf, size_t size) {
  if (item->opt_list) {
    unsigned max_opt_len = 0;
    for (unsigned i = 0; item->opt_list[i]; i++)
      max_opt_len = MAX(max_opt_len, strlen(item->opt_list[i]));
    snprintf(buf, size, "%-30s <%s>", item->str, item->opt_list[item->opt_idx]);
  } else {
    snprintf(buf, size, "%s", item->str);
  }
}

static void menu_item_action(MenuItem_t *item) {
  if (item->opt_list) {
    unsigned n_opts = 0;
    while (item->opt_list[n_opts])
      n_opts++;
    item->opt_idx = (item->opt_idx + 1) % n_opts;
  }

  if (item->action)
    item->action(item, item->opaque);
}

void menu_draw() {
  const Menu_t *menu = curr_menu;
  osd_clear();
  // Draw menu banner
  osd_printf(0, 1, " %s", menu->title);
  for (unsigned i = 0; i < 3; i++)
    osd_invert(0, i, OSD_WIDTH);
  // Draw menu items
  unsigned row = 4;
  MenuItem_t *item = menu->first_item;
  while (item) {
    char buf[64];
    menu_item_print(item, buf, sizeof(buf));
    osd_printf(0, row, "%s", buf);
    if (menu->curr_item == item)
      osd_invert(0, row, OSD_WIDTH);
    item = item->next;
    row++;
  }
  osd_flush();
}

void menu_input_up() {
  if (curr_menu->curr_item->prev)
    curr_menu->curr_item = curr_menu->curr_item->prev;
}

void menu_input_down() {
  if (curr_menu->curr_item->next)
    curr_menu->curr_item = curr_menu->curr_item->next;
}

void menu_input_select() { menu_item_action(curr_menu->curr_item); }

void menu_input_back() {
  if (curr_menu->parent)
    curr_menu = curr_menu->parent;
}

void menu_action_jump_menu(struct MenuItem *item, void *opaque) { curr_menu = (Menu_t *)opaque; }
