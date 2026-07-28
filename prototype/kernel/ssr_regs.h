/* SPDX-License-Identifier: BSD-2-Clause-Views */
#ifndef SSR_REGS_H
#define SSR_REGS_H

#define SSR_APP_ID 0x53535201
#define SSR_RB_TYPE 0x53535201
#define SSR_RB_VERSION 0x00000100
#define SSR_MAX_REPLICAS 7

#define SSR_AUXILIARY_NAME "mqnic.app_53535201"

/* register block headers */
#define SSR_REG_TYPE        0x00
#define SSR_REG_VERSION     0x04
#define SSR_REG_NEXTPTR     0x08
#define SSR_REG_FEATURES    0x0c

/* control and status registers */
#define SSR_REG_CTRL         0x10
#define SSR_REG_STATUS       0x14
#define SSR_REG_ERROR        0x18
#define SSR_REG_SCRATCH      0x1c

/* replica configuration */
#define SSR_REG_REPLICA_ID      0x20
#define SSR_REG_REPLICA_COUNT   0x24
#define SSR_REG_ROUND_LENGTH_NS 0x28
#define SSR_REG_ETHERNET_TYPE   0x2c

/* replica MAC table */
#define SSR_REG_MAC_TABLE_BASE          0x100
#define SSR_REG_MAC_TABLE_STRIDE        0x08    // 8 bytes per entry (MAC address)
#define SSR_REG_MAC_LOW_OFFSET          0x00
#define SSR_REG_MAC_HIGH_OFFSET         0x04

#endif /* SSR_REGS_H */
