/* CI-only automatic littlefs smoke test for qemu-vexpress-a9. */
#include <rtthread.h>
#include <rtdevice.h>

#include <dfs_fs.h>
#include <dfs_file.h>
#include <dfs_romfs.h>

#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#include <stdio.h>
#include <string.h>
#if defined(DFS_USING_POSIX)
#include <dirent.h>
#endif /* defined(DFS_USING_POSIX) */

#define LFS_SMOKE_DEV        "lfsnor"
#define LFS_SMOKE_MNT        "/lfs"
#define LFS_SMOKE_FILE       "/lfs/hello.txt"
#define LFS_SMOKE_DIR        "/lfs/dir1"
#define LFS_SMOKE_PAYLOAD    "hello-littlefs-ci"
#define LFS_SMOKE_PAYLOAD_LEN (sizeof(LFS_SMOKE_PAYLOAD) - 1U)

#if defined(RT_USING_DFS_V2)
/** @brief Absolute pseudo-source path accepted by DFS v2 pseudo filesystems. */
#define LFS_SMOKE_PSEUDO_SOURCE "/"
#else
/** @brief Legacy pseudo-filesystem source argument. */
#define LFS_SMOKE_PSEUDO_SOURCE RT_NULL
#endif /* defined(RT_USING_DFS_V2) */

/** @brief RT-Thread device object name used by dfs_mkfs() and dfs_mount(). */
#define LFS_SMOKE_DFS_DEVICE    LFS_SMOKE_DEV

/**
 * @brief ROMFS child entries used to provide stable smoke-test mount points.
 */
static const struct romfs_dirent littlefs_smoke_romfs_entries[] =
{
    { ROMFS_DIRENT_DIR, "dev", RT_NULL, 0 },
    { ROMFS_DIRENT_DIR, "lfs", RT_NULL, 0 },
};

/**
 * @brief ROMFS root directory used to provide stable smoke-test mount points.
 */
static const struct romfs_dirent littlefs_smoke_romfs_root =
{
    ROMFS_DIRENT_DIR,
    "/",
    (const rt_uint8_t *)littlefs_smoke_romfs_entries,
    sizeof(littlefs_smoke_romfs_entries) /
        sizeof(littlefs_smoke_romfs_entries[0]),
};

/**
 * @brief Print a smoke-test failure marker and return the error code.
 *
 * @param step Name of the failed smoke-test step.
 * @param err Error code returned by the failed step.
 * @return The original error code, or -RT_ERROR when err is 0.
 */
static int littlefs_smoke_fail(const char *step, int err)
{
    rt_kprintf("LITTLEFS_SMOKE_FAIL step=%s err=%d\n", step, err);
    return err != 0 ? err : -RT_ERROR;
}

/**
 * @brief Verify that the smoke-test file can be read and matches the payload.
 *
 * @return RT_EOK on success, otherwise an RT-Thread error code.
 */
static int littlefs_smoke_read_file(void)
{
    int fd;
    int ret;
    char buf[32];

    rt_memset(buf, 0, sizeof(buf));
    fd = open(LFS_SMOKE_FILE, O_RDONLY, 0);
    if (fd < 0)
    {
        return littlefs_smoke_fail("open-read", fd);
    }

    ret = read(fd, buf, sizeof(buf) - 1U);
    close(fd);
    if (ret < 0)
    {
        return littlefs_smoke_fail("read", ret);
    }

    if (strcmp(buf, LFS_SMOKE_PAYLOAD) != 0)
    {
        rt_kprintf("LITTLEFS_SMOKE_FAIL step=compare got=%s\n", buf);
        return -RT_ERROR;
    }

    return RT_EOK;
}

/**
 * @brief Verify directory traversal through the mounted littlefs filesystem.
 *
 * @return RT_EOK on success, otherwise an RT-Thread error code.
 */
static int littlefs_smoke_list_dir(void)
{
#if defined(DFS_USING_POSIX)
    DIR *dir;
    struct dirent *entry;
    int found_file = 0;
    int found_dir = 0;

    dir = opendir(LFS_SMOKE_MNT);
    if (dir == RT_NULL)
    {
        return littlefs_smoke_fail("opendir", -RT_ERROR);
    }

    while ((entry = readdir(dir)) != RT_NULL)
    {
        if (rt_strcmp(entry->d_name, "hello.txt") == 0)
        {
            found_file = 1;
        }
        else if (rt_strcmp(entry->d_name, "dir1") == 0)
        {
            found_dir = 1;
        }
    }
    closedir(dir);

    if (!found_file || !found_dir)
    {
        rt_kprintf("LITTLEFS_SMOKE_FAIL step=readdir file=%d dir=%d\n",
                   found_file, found_dir);
        return -RT_ERROR;
    }

    return RT_EOK;
#else
    int fd;
    int ret;
    int found_file = 0;
    int found_dir = 0;
    struct dirent entries[4];

    fd = open(LFS_SMOKE_MNT, O_RDONLY | O_DIRECTORY, 0);
    if (fd < 0)
    {
        return littlefs_smoke_fail("open-dir", fd);
    }

    do
    {
        int index;

        rt_memset(entries, 0, sizeof(entries));
        ret = getdents(fd, entries, sizeof(entries));
        if (ret < 0)
        {
            close(fd);
            return littlefs_smoke_fail("getdents", ret);
        }

        for (index = 0; index < ret / (int)sizeof(struct dirent); index++)
        {
            if (rt_strcmp(entries[index].d_name, "hello.txt") == 0)
            {
                found_file = 1;
            }
            else if (rt_strcmp(entries[index].d_name, "dir1") == 0)
            {
                found_dir = 1;
            }
        }
    } while (ret > 0);

    close(fd);
    if (!found_file || !found_dir)
    {
        rt_kprintf("LITTLEFS_SMOKE_FAIL step=getdents-scan file=%d dir=%d\n",
                   found_file, found_dir);
        return -RT_ERROR;
    }

    return RT_EOK;
#endif /* defined(DFS_USING_POSIX) */
}

/**
 * @brief Prepare stable root, device, and littlefs mount-point filesystems.
 *
 * The qemu-vexpress-a9 BSP root filesystem depends on SD-card FAT behavior
 * that differs across RT-Thread DFS versions. Mount a static ROMFS root with
 * /dev and /lfs entries so the smoke test does not depend on ELMFAT, SD
 * auto-mount, tmpfs, or mounting littlefs as root. DFS v2 mounts devfs at
 * /dev during component initialization, so the smoke test does not remount it.
 *
 * @return RT_EOK on success, otherwise an RT-Thread error code.
 */
static int littlefs_smoke_prepare_rootfs(void)
{
    int ret;

    ret = dfs_mount(LFS_SMOKE_PSEUDO_SOURCE,
                    "/",
                    "rom",
                    0,
                    (const void *)&littlefs_smoke_romfs_root);
    rt_kprintf("LITTLEFS_SMOKE_INFO mount romfs root ret=%d\n", ret);
    if (ret != 0)
    {
        return littlefs_smoke_fail("mount-root-romfs", ret);
    }

#if defined(RT_USING_DFS_V2)
    rt_kprintf("LITTLEFS_SMOKE_INFO use existing devfs mount\n");
#endif /* defined(RT_USING_DFS_V2) */

    return RT_EOK;
}

/**
 * @brief Run the automatic littlefs filesystem smoke test.
 *
 * @return RT_EOK on success, otherwise an RT-Thread error code.
 */
static int littlefs_smoke_run(void)
{
    int fd;
    int ret;

    rt_kprintf("LITTLEFS_SMOKE_START dev=%s\n", LFS_SMOKE_DEV);

    ret = littlefs_smoke_prepare_rootfs();
    if (ret != RT_EOK)
    {
        return ret;
    }

    ret = dfs_mkfs("lfs", LFS_SMOKE_DFS_DEVICE);
    if (ret != 0)
    {
        return littlefs_smoke_fail("mkfs", ret);
    }

    ret = dfs_mount(LFS_SMOKE_DFS_DEVICE, LFS_SMOKE_MNT, "lfs", 0, RT_NULL);
    if (ret != 0)
    {
        return littlefs_smoke_fail("mount", ret);
    }

    fd = open(LFS_SMOKE_FILE, O_CREAT | O_RDWR | O_TRUNC, 0666);
    if (fd < 0)
    {
        return littlefs_smoke_fail("open-write", fd);
    }

    ret = write(fd, LFS_SMOKE_PAYLOAD, LFS_SMOKE_PAYLOAD_LEN);
    close(fd);
    if (ret != (int)LFS_SMOKE_PAYLOAD_LEN)
    {
        return littlefs_smoke_fail("write", ret);
    }

    ret = mkdir(LFS_SMOKE_DIR, 0);
    if (ret != 0)
    {
        return littlefs_smoke_fail("mkdir-dir", ret);
    }

    ret = littlefs_smoke_read_file();
    if (ret != RT_EOK)
    {
        return ret;
    }

    ret = littlefs_smoke_list_dir();
    if (ret != RT_EOK)
    {
        return ret;
    }

    ret = dfs_unmount(LFS_SMOKE_MNT);
    if (ret != 0)
    {
        return littlefs_smoke_fail("unmount", ret);
    }

    ret = dfs_mount(LFS_SMOKE_DFS_DEVICE, LFS_SMOKE_MNT, "lfs", 0, RT_NULL);
    if (ret != 0)
    {
        return littlefs_smoke_fail("remount", ret);
    }

    ret = littlefs_smoke_read_file();
    if (ret != RT_EOK)
    {
        return ret;
    }

    ret = littlefs_smoke_list_dir();
    if (ret != RT_EOK)
    {
        return ret;
    }

    ret = dfs_unmount(LFS_SMOKE_MNT);
    if (ret != 0)
    {
        return littlefs_smoke_fail("final-unmount", ret);
    }

    rt_kprintf("LITTLEFS_SMOKE_PASS\n");
    return RT_EOK;
}
INIT_APP_EXPORT(littlefs_smoke_run);
