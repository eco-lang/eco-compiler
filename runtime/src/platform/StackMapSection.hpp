// StackMapSection.hpp — locate the LLVM stackmaps section of a loaded
// module: ".llvm_stackmaps" on ELF, "__LLVM_STACKMAPS,__llvm_stackmaps" on
// Mach-O. This is the platform seam unifying what were two near-identical
// ELF walks in eco_entry.cpp (main executable only) and eco_embed.cpp
// (module containing an address).
//
// On both platforms the loader applies the section's relocations before we
// read it (verified for Mach-O by experiments/mac-statepoint-smoke — dyld
// rebases the recorded function addresses), so callers parse the returned
// bytes with loadBase=0.
//
// Header-only: the ELF implementation reads the module's file from disk
// (dl_iterate_phdr exposes program headers, not sections), the Mach-O one
// reads the in-memory image via getsectiondata.

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

struct StackMapSection {
    const uint8_t* data = nullptr;
    size_t size = 0;
};

#if defined(_WIN32)

// addr == nullptr → main executable (current module); otherwise the module
// containing addr, found via GetModuleHandleEx(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS).
// Section name on PE COFF is ".llvm_stackmaps" — verified by E-W1
// (experiments/win-statepoint-smoke). The loader applies base relocations
// to the section's content, so the recorded function addresses match what
// stack walking will surface; callers parse with loadBase=0 like the
// other platforms. See plans/build-on-windows.md item 13.
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
        // COFF short-form section names are 8 bytes, NUL-padded. The
        // stackmap section's name is 15 chars, but PE truncates the field
        // and the linker can store the full name in the string table via
        // a "/NN" indirection. Match on the 8-byte prefix ".llvm_st"
        // which is unique inside our binaries — verified by E-W1.
        if (std::memcmp(sec->Name, ".llvm_st", 8) == 0) {
            DWORD size = sec->Misc.VirtualSize ? sec->Misc.VirtualSize
                                               : sec->SizeOfRawData;
            return {base + sec->VirtualAddress, static_cast<size_t>(size)};
        }
    }
    return {};
}

#elif defined(__APPLE__)

// addr == nullptr → main executable; otherwise the image containing addr
// (an executable OR a dlopen'd / linked shared object), found via dladdr.
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
                // The main executable's name: glibc reports "" (empty);
                // musl-static reports "/proc/self/exe". Accept either.
                // NB: a `dlpi_name[0] != '\0'` test alone is a glibc-ism —
                // on musl it skips the main executable, so .llvm_stackmaps
                // is never found and the GC scans zero stack roots (live
                // stack-referenced objects get reclaimed, corrupting the
                // heap).
                const char* nm = info->dlpi_name;
                bool is_main = (nm == nullptr) || (nm[0] == '\0') ||
                               (std::strcmp(nm, "/proc/self/exe") == 0);
                if (!is_main)
                    return 0;
            } else {
                // Does any PT_LOAD segment of this module contain target?
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

            // Read the module's section headers from its file on disk. The
            // main executable reports an empty name — fall back to
            // /proc/self/exe for it.
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
                    // sh_addr is the link-time virtual address; add the
                    // module's load base for PIE/shared objects.
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
