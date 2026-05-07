/* CI-only RAM-backed MTD NOR device for littlefs smoke tests. */
#include <rtthread.h>
#include <rtdevice.h>

#define QEMU_LFS_MTD_BLOCK_SIZE   4096U
#define QEMU_LFS_MTD_BLOCK_COUNT  128U
#define QEMU_LFS_MTD_TOTAL_SIZE   (QEMU_LFS_MTD_BLOCK_SIZE * QEMU_LFS_MTD_BLOCK_COUNT)

/** @brief Number of RAM-backed MTD NOR devices used by the smoke test. */
#define QEMU_LFS_MTD_DEVICE_COUNT 2U

/**
 * @brief One RAM-backed MTD NOR instance used by the QEMU smoke test.
 */
typedef struct
{
    struct rt_mtd_nor_device device;          /**< RT-Thread MTD NOR device. */
    rt_uint8_t storage[QEMU_LFS_MTD_TOTAL_SIZE]; /**< Backing flash bytes. */
    const char *name;                         /**< Registered device name. */
} qemu_lfs_mtd_instance_t;

/**
 * @brief RAM-backed MTD NOR devices used only for QEMU littlefs smoke tests.
 */
static qemu_lfs_mtd_instance_t qemu_lfs_mtd_devices[QEMU_LFS_MTD_DEVICE_COUNT] =
{
    { .name = "lfsroot" },
    { .name = "lfsnor"  },
};

/**
 * @brief Find backing storage for an MTD NOR operation.
 *
 * @param device MTD NOR device passed by DFS/littlefs.
 * @return Backing storage buffer, or RT_NULL for an unknown device.
 */
static rt_uint8_t *qemu_lfs_mtd_storage_of(struct rt_mtd_nor_device *device)
{
    rt_size_t index;

    for (index = 0U; index < QEMU_LFS_MTD_DEVICE_COUNT; index++)
    {
        if (&qemu_lfs_mtd_devices[index].device == device)
        {
            return qemu_lfs_mtd_devices[index].storage;
        }
    }

    return RT_NULL;
}

/**
 * @brief Accept an MTD NOR ID read request for the smoke-test device.
 *
 * The targeted RT-Thread releases declare the read_id driver op as returning
 * rt_err_t, while the public rt_mtd_nor_read_id wrapper returns rt_uint32_t.
 * The smoke test does not depend on a JEDEC ID value, so the RAM-backed device
 * reports only that the operation completed successfully.
 *
 * @param device MTD NOR device.
 * @return RT_EOK on success.
 */
static rt_err_t qemu_lfs_mtd_read_id(struct rt_mtd_nor_device *device)
{
    RT_UNUSED(device);

    return RT_EOK;
}

/**
 * @brief Return type used by RT-Thread MTD NOR read/write callbacks.
 */
#if RTTHREAD_VERSION >= RT_VERSION_CHECK(5, 0, 0)
typedef rt_ssize_t qemu_lfs_mtd_rw_ret_t;
#else
typedef rt_size_t qemu_lfs_mtd_rw_ret_t;
#endif /* RTTHREAD_VERSION >= RT_VERSION_CHECK(5, 0, 0) */

/**
 * @brief Length type used by RT-Thread MTD NOR callbacks.
 */
#if RTTHREAD_VERSION >= RT_VERSION_CHECK(5, 0, 0)
typedef rt_size_t qemu_lfs_mtd_len_t;
#else
typedef rt_uint32_t qemu_lfs_mtd_len_t;
#endif /* RTTHREAD_VERSION >= RT_VERSION_CHECK(5, 0, 0) */

/**
 * @brief Read bytes from the RAM-backed MTD NOR device.
 *
 * @param device MTD NOR device.
 * @param offset Byte offset in the emulated NOR storage.
 * @param data Destination buffer.
 * @param length Number of bytes to read.
 * @return Number of bytes read, or 0 on out-of-range access.
 */
static qemu_lfs_mtd_rw_ret_t qemu_lfs_mtd_read(struct rt_mtd_nor_device *device,
                                               rt_off_t offset,
                                               rt_uint8_t *data,
                                               qemu_lfs_mtd_len_t length)
{
    rt_uint8_t *storage = qemu_lfs_mtd_storage_of(device);

    if ((storage == RT_NULL) || (data == RT_NULL) || (offset < 0) ||
        ((rt_size_t)offset >= QEMU_LFS_MTD_TOTAL_SIZE) ||
        (length > QEMU_LFS_MTD_TOTAL_SIZE - (rt_size_t)offset))
    {
        return 0;
    }

    rt_memcpy(data, &storage[offset], length);
    return (qemu_lfs_mtd_rw_ret_t)length;
}

/**
 * @brief Write bytes to the RAM-backed MTD NOR device.
 *
 * @param device MTD NOR device.
 * @param offset Byte offset in the emulated NOR storage.
 * @param data Source buffer.
 * @param length Number of bytes to write.
 * @return Number of bytes written, or 0 on out-of-range access.
 */
static qemu_lfs_mtd_rw_ret_t qemu_lfs_mtd_write(struct rt_mtd_nor_device *device,
                                                rt_off_t offset,
                                                const rt_uint8_t *data,
                                                qemu_lfs_mtd_len_t length)
{
    rt_uint8_t *storage = qemu_lfs_mtd_storage_of(device);

    if ((storage == RT_NULL) || (data == RT_NULL) || (offset < 0) ||
        ((rt_size_t)offset >= QEMU_LFS_MTD_TOTAL_SIZE) ||
        (length > QEMU_LFS_MTD_TOTAL_SIZE - (rt_size_t)offset))
    {
        return 0;
    }

    rt_memcpy(&storage[offset], data, length);
    return (qemu_lfs_mtd_rw_ret_t)length;
}

/**
 * @brief Erase one or more blocks in the RAM-backed MTD NOR device.
 *
 * @param device MTD NOR device.
 * @param offset Byte offset in the emulated NOR storage.
 * @param length Number of bytes to erase.
 * @return RT_EOK on success, otherwise an RT-Thread error code.
 */
static rt_err_t qemu_lfs_mtd_erase(struct rt_mtd_nor_device *device,
                                   rt_off_t offset,
                                   qemu_lfs_mtd_len_t length)
{
    rt_uint8_t *storage = qemu_lfs_mtd_storage_of(device);

    if ((storage == RT_NULL) || (offset < 0) ||
        ((rt_size_t)offset >= QEMU_LFS_MTD_TOTAL_SIZE) ||
        (length > QEMU_LFS_MTD_TOTAL_SIZE - (rt_size_t)offset))
    {
        return -RT_EINVAL;
    }

    if (((rt_size_t)offset % QEMU_LFS_MTD_BLOCK_SIZE) != 0U ||
        (length % QEMU_LFS_MTD_BLOCK_SIZE) != 0U)
    {
        return -RT_EINVAL;
    }

    rt_memset(&storage[offset], 0xff, length);
    return RT_EOK;
}

/**
 * @brief MTD NOR operation table for the QEMU littlefs smoke-test device.
 */
static const struct rt_mtd_nor_driver_ops qemu_lfs_mtd_ops =
{
    .read_id     = qemu_lfs_mtd_read_id,
    .read        = qemu_lfs_mtd_read,
    .write       = qemu_lfs_mtd_write,
    .erase_block = qemu_lfs_mtd_erase,
};

/**
 * @brief Register a RAM-backed MTD NOR device for littlefs smoke tests.
 *
 * @return RT_EOK on success, otherwise an RT-Thread error code.
 */
static int qemu_lfs_mtd_init(void)
{
    rt_size_t index;

    for (index = 0U; index < QEMU_LFS_MTD_DEVICE_COUNT; index++)
    {
        rt_err_t ret;

        rt_memset(qemu_lfs_mtd_devices[index].storage,
                  0xff,
                  sizeof(qemu_lfs_mtd_devices[index].storage));
        rt_memset(&qemu_lfs_mtd_devices[index].device,
                  0,
                  sizeof(qemu_lfs_mtd_devices[index].device));

        qemu_lfs_mtd_devices[index].device.block_start = 0;
        qemu_lfs_mtd_devices[index].device.block_end = QEMU_LFS_MTD_BLOCK_COUNT;
        qemu_lfs_mtd_devices[index].device.block_size = QEMU_LFS_MTD_BLOCK_SIZE;
        qemu_lfs_mtd_devices[index].device.ops = &qemu_lfs_mtd_ops;

        ret = rt_mtd_nor_register_device(qemu_lfs_mtd_devices[index].name,
                                         &qemu_lfs_mtd_devices[index].device);
        if (ret != RT_EOK)
        {
            return ret;
        }
    }

    return RT_EOK;
}
INIT_DEVICE_EXPORT(qemu_lfs_mtd_init);
