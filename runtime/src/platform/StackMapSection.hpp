// The garbage collector finds the stack roots of compiled code through the stack maps that LLVM emits into a
// section of the object file, and this component finds that section in a module the process has loaded.
//
// A module is the main executable or a shared object. The section has a different name on each object format:
// ".llvm_stackmaps" on ELF and PE (cut to 8 bytes in a PE image), and section "__llvm_stackmaps" of segment
// "__LLVM_STACKMAPS" on Mach-O.
// `findStackMapSection` returns the address and size of that section's bytes in the module's loaded image, and
// does not parse them.
//
// The stack maps record function addresses. This component assumes the loader has relocated the section's
// contents, so that those addresses are run-time addresses; a caller parses the bytes with a load base of 0.
//
// The lookup differs by format. ELF exposes only program headers at run time (`dl_iterate_phdr`), so the section
// headers are read from the module's file on disk and the section's link-time address is shifted by the module's
// load base. Mach-O and PE keep their section tables in the loaded image, which is searched in memory.

#pragma once

#include <cstddef>
#include <cstdint>

#if defined(_WIN32)
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <cstring>
#elif defined(__APPLE__)
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <mach-o/getsect.h>
#include <mach-o/ldsyms.h>
#else
#include <cstdio>
#include <cstring>
#include <elf.h>
#include <link.h>
#include <vector>
#endif

namespace eco::platform {

/**
 * The bytes of one module's stack map section, as they lie in its loaded image.
 *
 * `data` points into the module's image and stays valid while the module stays loaded. A null `data` means no
 * section was found, and then `size` is 0. `size` is the number of bytes at `data`; nothing enforces this, since
 * both members are public.
 */
struct StackMapSection {
    const uint8_t* data = nullptr;
    size_t size = 0;
};

#if defined(_WIN32)

// Returns the stack map section of the main executable when `addr` is null, and otherwise of the module whose
// image contains `addr`. Returns an empty section if there is no such module or it has no such section.
//
// The PE section is the first whose 8-byte short name is ".llvm_st", the first 8 characters of
// ".llvm_stackmaps". Its size is the section's virtual size, or its raw data size when the virtual size is 0.
// The module's reference count is not changed. Only 64-bit PE images are handled.
inline StackMapSection findStackMapSection(const void* addr) {
    HMODULE hmod = nullptr;
    if (addr == nullptr) {
        hmod = GetModuleHandleW(nullptr);
    } else if (!GetModuleHandleExW(
                   GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS |
                       GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                   reinterpret_cast<LPCWSTR>(addr), &hmod) ||
               hmod == nullptr) {
        return {};
    }
    auto* base = reinterpret_cast<const uint8_t*>(hmod);
    auto* dos = reinterpret_cast<const IMAGE_DOS_HEADER*>(base);
    if (dos->e_magic != IMAGE_DOS_SIGNATURE) return {};
    auto* nt = reinterpret_cast<const IMAGE_NT_HEADERS64*>(base + dos->e_lfanew);
    if (nt->Signature != IMAGE_NT_SIGNATURE) return {};

    const auto* sec = IMAGE_FIRST_SECTION(nt);
    for (unsigned i = 0; i < nt->FileHeader.NumberOfSections; ++i, ++sec) {
        // A section name field holds 8 bytes, so the 15-character name is stored truncated. A name written
        // as a "/NN" string-table reference instead would not match.
        if (std::memcmp(sec->Name, ".llvm_st", 8) == 0) {
            DWORD size = sec->Misc.VirtualSize ? sec->Misc.VirtualSize
                                               : sec->SizeOfRawData;
            return {base + sec->VirtualAddress, static_cast<size_t>(size)};
        }
    }
    return {};
}

#elif defined(__APPLE__)

// Returns the stack map section of the main executable when `addr` is null, and otherwise of the loaded image
// (executable or shared object) containing `addr`, as `dladdr` reports it. Returns an empty section if there is
// no such image, or it has no such section or an empty one. Only 64-bit Mach-O images are handled.
inline StackMapSection findStackMapSection(const void* addr) {
    const struct mach_header_64* header = nullptr;
    if (addr == nullptr) {
        header = &_mh_execute_header;
    } else {
        Dl_info info;
        if (dladdr(addr, &info) == 0 || info.dli_fbase == nullptr)
            return {};
        header = static_cast<const struct mach_header_64*>(info.dli_fbase);
    }
    unsigned long size = 0;
    uint8_t* data = getsectiondata(header, "__LLVM_STACKMAPS",
                                   "__llvm_stackmaps", &size);
    if (data == nullptr || size == 0)
        return {};
    return {data, static_cast<size_t>(size)};
}

#else // ELF

// Returns the stack map section of the main executable when `addr` is null, and otherwise of the module with a
// `PT_LOAD` segment containing `addr`. Returns an empty section if there is no such module, its file cannot be
// read, or it has no section named ".llvm_stackmaps".
//
// Reads the module's section headers from its file on disk, so each call that finds a module opens and reads a
// file. Only 64-bit ELF is handled.
inline StackMapSection findStackMapSection(const void* addr) {
    struct CallbackData {
        uintptr_t target; // 0 = the main executable
        const uint8_t* data;
        size_t size;
    };
    CallbackData cbd{reinterpret_cast<uintptr_t>(addr), nullptr, 0};

    dl_iterate_phdr(
        [](struct dl_phdr_info* info, size_t /*size*/, void* ctx) -> int {
            auto* out = static_cast<CallbackData*>(ctx);

            if (out->target == 0) {
                // glibc names the main executable "" (or null) and static musl names it "/proc/self/exe", so both
                // are accepted. Testing for "" alone would miss it under musl: no section would be found, the
                // collector would scan no stack roots, and live objects referenced from the stack would be freed.
                const char* nm = info->dlpi_name;
                bool is_main = (nm == nullptr) || (nm[0] == '\0') ||
                               (std::strcmp(nm, "/proc/self/exe") == 0);
                if (!is_main)
                    return 0;
            } else {
                bool contains = false;
                for (int i = 0; i < info->dlpi_phnum; ++i) {
                    const auto& ph = info->dlpi_phdr[i];
                    if (ph.p_type != PT_LOAD)
                        continue;
                    uintptr_t start = info->dlpi_addr + ph.p_vaddr;
                    if (out->target >= start &&
                        out->target < start + ph.p_memsz) {
                        contains = true;
                        break;
                    }
                }
                if (!contains)
                    return 0;
            }

            // The main executable may be reported with an empty name; its file is /proc/self/exe.
            const char* path = info->dlpi_name;
            if (path == nullptr || path[0] == '\0')
                path = "/proc/self/exe";

            FILE* f = std::fopen(path, "rb");
            if (!f)
                return 0;

            Elf64_Ehdr ehdr;
            if (std::fread(&ehdr, sizeof(ehdr), 1, f) != 1) {
                std::fclose(f);
                return 0;
            }

            Elf64_Shdr shstrtab_hdr;
            if (std::fseek(f, ehdr.e_shoff + ehdr.e_shstrndx * ehdr.e_shentsize,
                           SEEK_SET) != 0 ||
                std::fread(&shstrtab_hdr, sizeof(shstrtab_hdr), 1, f) != 1) {
                std::fclose(f);
                return 0;
            }
            std::vector<char> shstrtab(shstrtab_hdr.sh_size);
            if (std::fseek(f, shstrtab_hdr.sh_offset, SEEK_SET) != 0 ||
                std::fread(shstrtab.data(), shstrtab_hdr.sh_size, 1, f) != 1) {
                std::fclose(f);
                return 0;
            }

            for (uint16_t i = 0; i < ehdr.e_shnum; i++) {
                Elf64_Shdr shdr;
                if (std::fseek(f, ehdr.e_shoff + i * ehdr.e_shentsize,
                               SEEK_SET) != 0 ||
                    std::fread(&shdr, sizeof(shdr), 1, f) != 1)
                    continue;
                if (shdr.sh_name >= shstrtab_hdr.sh_size)
                    continue;
                const char* name = shstrtab.data() + shdr.sh_name;
                if (std::strcmp(name, ".llvm_stackmaps") == 0) {
                    // sh_addr is the link-time address; dlpi_addr is the module's load base.
                    out->data = reinterpret_cast<const uint8_t*>(
                        info->dlpi_addr + shdr.sh_addr);
                    out->size = shdr.sh_size;
                    std::fclose(f);
                    return 1; // stop iteration
                }
            }
            std::fclose(f);
            return 0;
        },
        &cbd);

    return {cbd.data, cbd.size};
}

#endif // platform

} // namespace eco::platform
