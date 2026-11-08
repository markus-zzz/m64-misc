#ifndef M64_LEDS_H
#define M64_LEDS_H

void leds_setup_pins(void);
void leds_set_ctrl(uint8_t port, uint32_t rgb); /* port=0,1,2,3 */

#endif /* M64_LEDS_H */
