/* CI-only RT-Thread package integration check. */
#include <rtthread.h>

/* Match the package SConscript compile flag while including the real API. */
/**
 * @brief Select the package-local RT-Thread littlefs configuration header.
 */
#define LFS_CONFIG lfs_config.h
#include "../packages/littlefs/lfs.h"

/**
 * @brief Initialize the RT-Thread DFS littlefs package.
 *
 * @return 0 on success, otherwise a negative error code.
 */
extern int dfs_lfs_init(void);

/**
 * @brief Verify that package build graph linked littlefs symbols.
 *
 * @return 0 when required symbols are linked, otherwise -1.
 */
static int littlefs_compile_check(void)
{
    int (* volatile dfs_init)(void) = dfs_lfs_init;
    int (* volatile mount)(lfs_t *, const struct lfs_config *) = lfs_mount;

    return (dfs_init != 0 && mount != 0) ? 0 : -1;
}
INIT_APP_EXPORT(littlefs_compile_check);
