// SPDX-License-Identifier: BSD-2-Clause-Views
/*
 * mqnic SSR application auxiliary driver
 */

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/init.h>
#include <linux/io.h>
#include <linux/mutex.h>
#include <linux/device.h>
#include <linux/auxiliary_bus.h>
#include <linux/sysfs.h>
#include <linux/slab.h>

#include "mqnic.h"
#include "ssr_regs.h"

#define DRV_NAME "mqnic_app_ssr"

struct mqnic_app_ssr {
    struct device *dev;
    struct mqnic_dev *mdev;

    void __iomem *app_hw_addr;
    resource_size_t app_hw_size;

    struct mqnic_reg_block *app_rb_list;
    struct mqnic_reg_block *ssr_rb;

    struct mutex lock;
};

static inline u32 ssr_readl(struct mqnic_app_ssr *app_ssr, u32 reg)
{
    return ioread32(app_ssr->ssr_rb->regs + reg);
}

static inline void ssr_writel(struct mqnic_app_ssr *app_ssr, u32 reg, u32 value)
{
    iowrite32(value, app_ssr->ssr_rb->regs + reg);
}

/*
 * ssr_self_test - Perform self-test on the SSR
 * @app_ssr: SSR application structure
 *
 * Returns 0 on success, negative error code on failure.
 */
static int ssr_self_test(struct mqnic_app_ssr *app_ssr)
{
    u32 type;
    u32 version;
    u32 features;
    u32 val;

    type = ssr_readl(app_ssr, SSR_REG_TYPE);
    version = ssr_readl(app_ssr, SSR_REG_VERSION);
    features = ssr_readl(app_ssr, SSR_REG_FEATURES);

    dev_info(app_ssr->dev, "SSR TYPE: 0x%08x\n", type);
    dev_info(app_ssr->dev, "SSR VERSION: 0x%08x\n", version);
    dev_info(app_ssr->dev, "SSR FEATURES: 0x%08x\n", features);
    
    if (type != SSR_RB_TYPE) {
        dev_err(app_ssr->dev, "Invalid SSR type: 0x%08x\n", type);
        return -ENODEV;
    }

    if (version != SSR_RB_VERSION) {
        dev_err(app_ssr->dev, "Unsupported SSR version: 0x%08x\n", version);
        return -ENODEV;
    }

    ssr_writel(app_ssr, SSR_REG_SCRATCH, 0xdeadbeef);
    val = ssr_readl(app_ssr, SSR_REG_SCRATCH);
    if (val != 0xdeadbeef) {
        dev_err(app_ssr->dev, "SSR self-test failed: expected 0xdeadbeef, got 0x%08x\n", val);
        return -EIO;
    }

    dev_info(app_ssr->dev, "SSR self-test passed\n");

    return 0;
}

// sysfs: features
static ssize_t features_show(struct device *dev, 
                            struct device_attribute *attr, 
                            char *buf)
{
    struct mqnic_app_ssr *app_ssr = dev_get_drvdata(dev);
    u32 val;

    mutex_lock(&app_ssr->lock);
    val = ssr_readl(app_ssr, SSR_REG_FEATURES);
    mutex_unlock(&app_ssr->lock);

    return sysfs_emit(buf, "0x%08x\n", val);
}
static DEVICE_ATTR_RO(features);


// sysfs: status
static ssize_t status_show(struct device *dev, 
                            struct device_attribute *attr, 
                            char *buf)
{
    struct mqnic_app_ssr *app_ssr = dev_get_drvdata(dev);
    u32 val;

    mutex_lock(&app_ssr->lock);
    val = ssr_readl(app_ssr, SSR_REG_STATUS);
    mutex_unlock(&app_ssr->lock);

    return sysfs_emit(buf, "0x%08x\n", val);
}
static DEVICE_ATTR_RO(status);

// sysfs: control
static ssize_t control_show(struct device *dev, 
                            struct device_attribute *attr, 
                            char *buf)
{
    struct mqnic_app_ssr *app_ssr = dev_get_drvdata(dev);
    u32 val;

    mutex_lock(&app_ssr->lock);
    val = ssr_readl(app_ssr, SSR_REG_CTRL);
    mutex_unlock(&app_ssr->lock);

    return sysfs_emit(buf, "0x%08x\n", val);
}

static ssize_t control_store(struct device *dev,
                            struct device_attribute *attr, 
                            const char *buf, 
                            size_t count)
{
    struct mqnic_app_ssr *app_ssr = dev_get_drvdata(dev);
    u32 val;
    int ret;

    ret = kstrtou32(buf, 0, &val);
    if (ret)
        return ret;

    mutex_lock(&app_ssr->lock);
    ssr_writel(app_ssr, SSR_REG_CTRL, val);
    mutex_unlock(&app_ssr->lock);

    return count;
}
static DEVICE_ATTR_RW(control);

// sysfs: scratch
static ssize_t scratch_show(struct device *dev,
                            struct device_attribute *attr,
                            char *buf)
{    
    struct mqnic_app_ssr *app_ssr = dev_get_drvdata(dev);
    u32 val;

    mutex_lock(&app_ssr->lock);
    val = ssr_readl(app_ssr, SSR_REG_SCRATCH);
    mutex_unlock(&app_ssr->lock);

    return sysfs_emit(buf, "0x%08x\n", val);
}
static ssize_t scratch_store(struct device *dev,
                            struct device_attribute *attr,
                            const char *buf,
                            size_t count)
{
    struct mqnic_app_ssr *app_ssr = dev_get_drvdata(dev);
    u32 val;
    int ret;

    ret = kstrtou32(buf, 0, &val);
    if (ret)
        return ret;

    mutex_lock(&app_ssr->lock);
    ssr_writel(app_ssr, SSR_REG_SCRATCH, val);
    mutex_unlock(&app_ssr->lock);

    return count;
}
static DEVICE_ATTR_RW(scratch);

/*
 * sysfs: config
 *
 * Usage:
 *    echo "replica_id replica_count round_length_ns ethernet_type" > config
 *
 * Example:
 *    echo "0 4 2048 1777" > config
 */
static ssize_t config_store(struct device *dev,
                            struct device_attribute *attr, 
                            const char *buf, 
                            size_t count)
{
    struct mqnic_app_ssr *app_ssr = dev_get_drvdata(dev);
    u32 replica_id, replica_count, round_length_ns, ethernet_type;
    int ret;

    ret = sscanf(buf, "%u %u %u %u", &replica_id, &replica_count, &round_length_ns, &ethernet_type);
    if (ret != 4)
        return -EINVAL;

    mutex_lock(&app_ssr->lock);
    ssr_writel(app_ssr, SSR_REG_REPLICA_ID, replica_id);
    ssr_writel(app_ssr, SSR_REG_REPLICA_COUNT, replica_count);
    ssr_writel(app_ssr, SSR_REG_ROUND_LENGTH_NS, round_length_ns);
    ssr_writel(app_ssr, SSR_REG_ETHERNET_TYPE, ethernet_type);
    mutex_unlock(&app_ssr->lock);

    dev_info(app_ssr->dev, "SSR config updated: replica_id=%u, replica_count=%u, round_length_ns=%u, ethernet_type=%u\n",
             replica_id, replica_count, round_length_ns, ethernet_type);

    return count;
}

static ssize_t config_show(struct device *dev,
                            struct device_attribute *attr, 
                            char *buf)
{
    struct mqnic_app_ssr *app_ssr = dev_get_drvdata(dev);
    u32 replica_id, replica_count, round_length_ns, ethernet_type;

    mutex_lock(&app_ssr->lock);
    replica_id = ssr_readl(app_ssr, SSR_REG_REPLICA_ID);
    replica_count = ssr_readl(app_ssr, SSR_REG_REPLICA_COUNT);
    round_length_ns = ssr_readl(app_ssr, SSR_REG_ROUND_LENGTH_NS);
    ethernet_type = ssr_readl(app_ssr, SSR_REG_ETHERNET_TYPE);
    mutex_unlock(&app_ssr->lock);

    return sysfs_emit(buf, "%u %u %u %u\n", replica_id, replica_count, round_length_ns, ethernet_type);
}
static DEVICE_ATTR_RW(config);

/*
 * sysfs: mac_table
 * 
 * Usage:
 *    echo "index mac_address" > mac_table
 * 
 * Example:
 *    echo "0 00:11:22:33:44:55" > mac_table
 */
static ssize_t mac_table_store(struct device *dev,
                            struct device_attribute *attr, 
                            const char *buf, 
                            size_t count)
{   
    struct mqnic_app_ssr *app_ssr = dev_get_drvdata(dev);
    unsigned int index;
    unsigned int b0, b1, b2, b3, b4, b5;
    u32 mac_low, mac_high, base;

    int ret = sscanf(buf, "%u %02x:%02x:%02x:%02x:%02x:%02x", 
                     &index, &b0, &b1, &b2, &b3, &b4, &b5);
    if (ret != 7)
        return -EINVAL;

    if (index >= SSR_MAX_REPLICAS || b0 > 0xff || b1 > 0xff || b2 > 0xff || b3 > 0xff || b4 > 0xff || b5 > 0xff)
        return -EINVAL;

    mac_low = b0 | (b1 << 8) | (b2 << 16) | (b3 << 24);
    mac_high = b4 | (b5 << 8);

    base = SSR_REG_MAC_TABLE_BASE + index * SSR_REG_MAC_TABLE_STRIDE;

    mutex_lock(&app_ssr->lock);
    ssr_writel(app_ssr, base + SSR_REG_MAC_LOW_OFFSET, mac_low);
    ssr_writel(app_ssr, base + SSR_REG_MAC_HIGH_OFFSET, mac_high);
    mutex_unlock(&app_ssr->lock);

    dev_info(app_ssr->dev, "SSR MAC table updated: index=%u, mac_address=%02x:%02x:%02x:%02x:%02x:%02x\n",
             index, b0, b1, b2, b3, b4, b5);

    return count;
}

static ssize_t mac_table_show(struct device *dev,
                              struct device_attribute *attr,
                              char *buf)
{
    struct mqnic_app_ssr *app_ssr = dev_get_drvdata(dev);
    ssize_t len = 0;
    unsigned int index;

    mutex_lock(&app_ssr->lock);

    for (index = 0; index < SSR_MAX_REPLICAS; index++) {
        u32 base = SSR_REG_MAC_TABLE_BASE + index * SSR_REG_MAC_TABLE_STRIDE;
        u32 mac_low = ssr_readl(app_ssr, base + SSR_REG_MAC_LOW_OFFSET);
        u32 mac_high = ssr_readl(app_ssr, base + SSR_REG_MAC_HIGH_OFFSET);

        len += sysfs_emit_at(buf, len,
            "%u %02x:%02x:%02x:%02x:%02x:%02x\n",
            index,
            mac_low & 0xff,
            (mac_low >> 8) & 0xff,
            (mac_low >> 16) & 0xff,
            (mac_low >> 24) & 0xff,
            mac_high & 0xff,
            (mac_high >> 8) & 0xff);
    }

    mutex_unlock(&app_ssr->lock);

    return len;
}

static DEVICE_ATTR_RW(mac_table);

static struct attribute *ssr_attrs[] = {
    &dev_attr_features.attr,
    &dev_attr_status.attr,
    &dev_attr_control.attr,
    &dev_attr_config.attr,
    &dev_attr_scratch.attr,
    &dev_attr_mac_table.attr,
    NULL,
};

static const struct attribute_group ssr_attr_group = {
    .attrs = ssr_attrs,
};

// auxiliary driver probe function
static int mqnic_app_ssr_probe(struct auxiliary_device *adev,
                               const struct auxiliary_device_id *id)
{
    struct device *dev = &adev->dev;
    struct mqnic_dev *mdev = container_of(adev, struct mqnic_adev, adev)->mdev;
    struct mqnic_app_ssr *ssr;
    int ret;

    dev_info(dev, "%s() called\n", __func__);

    // Check that required BAR regions are present
    if (!mdev->hw_addr || !mdev->app_hw_addr) {
        dev_err(dev, "Required BAR regions not present\n");
        return -EIO;
    }

    ssr = devm_kzalloc(dev, sizeof(*ssr), GFP_KERNEL);
    if (!ssr)   return -ENOMEM;

    ssr->dev = dev;
    ssr->mdev = mdev;
    ssr->app_hw_addr = mdev->app_hw_addr;
    ssr->app_hw_size = mdev->app_hw_regs_size;

    mutex_init(&ssr->lock);

    dev_set_drvdata(dev, ssr);

    ssr->app_rb_list = mqnic_enumerate_reg_block_list(
        ssr->app_hw_addr, 0, ssr->app_hw_size);

    if (!ssr->app_rb_list) {
        dev_err(dev, "Failed to enumerate register blocks\n");
        ret = -EIO;
        goto fail;
    }
    dev_info(dev, "Enumerated SSR register blocks:\n");
    {
        struct mqnic_reg_block *rb;
        for (rb = ssr->app_rb_list; rb->regs; rb++) {
            dev_info(dev, "  RB type=0x%08x version=0x%08x\n",
                     rb->type, rb->version);
        }
    }

    ssr->ssr_rb = mqnic_find_reg_block(ssr->app_rb_list, SSR_RB_TYPE, SSR_RB_VERSION, 0);
    if (!ssr->ssr_rb) {
        dev_err(dev, "Failed to find SSR register block\n");
        ret = -EIO;
        goto fail_free_rb_list;
    }

    ret = ssr_self_test(ssr);
    if (ret) {
        dev_err(dev, "SSR self-test failed\n");
        goto fail_free_rb_list;
    }

    ret = sysfs_create_group(&dev->kobj, &ssr_attr_group);
    if (ret) {
        dev_err(dev, "Failed to create sysfs group\n");
        goto fail_free_rb_list;
    }

    dev_info(dev, "SSR application driver loaded successfully\n");

    return 0;

fail_free_rb_list:
    mqnic_free_reg_block_list(ssr->app_rb_list);
    ssr->app_rb_list = NULL;
fail:
    dev_set_drvdata(dev, NULL);
    return ret;
}

// auxiliary driver remove function
static void mqnic_app_ssr_remove(struct auxiliary_device *adev)
{
    struct device *dev = &adev->dev;
    struct mqnic_app_ssr *ssr = dev_get_drvdata(dev);

    dev_info(dev, "%s() called\n", __func__);

    if (!ssr) return;

    sysfs_remove_group(&dev->kobj, &ssr_attr_group);

    if (ssr->app_rb_list) {
        mqnic_free_reg_block_list(ssr->app_rb_list);
        ssr->app_rb_list = NULL;
    }

    dev_set_drvdata(dev, NULL);

    dev_info(dev, "SSR application driver removed\n");
}

static const struct auxiliary_device_id mqnic_app_ssr_id_table[] = {
    { .name = SSR_AUXILIARY_NAME },
    { },
};
MODULE_DEVICE_TABLE(auxiliary, mqnic_app_ssr_id_table);

static struct auxiliary_driver mqnic_app_ssr_driver = {
    .name = DRV_NAME,
    .id_table = mqnic_app_ssr_id_table,
    .probe = mqnic_app_ssr_probe,
    .remove = mqnic_app_ssr_remove,
};

static int __init mqnic_app_ssr_init(void)
{
    return auxiliary_driver_register(&mqnic_app_ssr_driver);
}

static void __exit mqnic_app_ssr_exit(void)
{
    auxiliary_driver_unregister(&mqnic_app_ssr_driver);
}

module_init(mqnic_app_ssr_init);
module_exit(mqnic_app_ssr_exit);

MODULE_DESCRIPTION("mqnic SSR application auxiliary driver");
MODULE_AUTHOR("Anonymous");
MODULE_LICENSE("Dual BSD/GPL");
MODULE_VERSION("0.1");
