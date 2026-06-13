# Build-time helper to (re)create the node_modules link inside the
# build-kernel shadow root after `pnpm install` has populated the source-tree
# node_modules. Used via:
#   cmake -DECO_TARGET=... -DECO_LINK=... -DECO_SOURCE_DIR=... -P this-file
#
# On Windows the junction can only be created once the target directory
# exists, so this script runs as a post-step of the pnpm-install custom
# command. On POSIX it is a defensive idempotent re-creation; the eager
# configure-time symbolic link already works because POSIX symlinks may
# point at nonexistent targets.

include(${ECO_SOURCE_DIR}/cmake/EcoCreateDirLink.cmake)
eco_create_dir_link(${ECO_TARGET} ${ECO_LINK})
