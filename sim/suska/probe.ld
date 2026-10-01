/* SPDX-License-Identifier: CERN-OHL-S-2.0
 * Copyright 2026 Romain Dolbeau
 * Source location: https://github.com/MelkhiorVintageComputing/RD68021
 */

/* The probe's image: vectors at 0, code at $400. */
SECTIONS
{
  . = 0;
  .vectors : { *(.vectors) }
  . = 0x400;
  .text : { *(.text) }
}
