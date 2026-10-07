//===- System.cpp - eco/system kernel module System ------------------------------===//
//
// Placeholder translation unit created in Phase 1 (plans/eco-system-library.md
// step 1.2) so the EcoSystem_System archive exists and links. The kernels of this
// module are implemented in later phases (Appendix B); see §3.3 before adding
// any C++ here.

namespace Eco::System {
extern const char* const kModuleSystem;
const char* const kModuleSystem = "System";
} // namespace Eco::System
