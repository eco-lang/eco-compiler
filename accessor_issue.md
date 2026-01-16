The problem is clear: arguments are specialized BEFORE call-site unification. When .name is processed, the substitution doesn't yet know the full record type. The call-site unification with List.map would bind the extension variable, but by then it's too late - the accessor already has a SpecId with the incomplete type.

  The fix is to defer accessor specialization until AFTER call-site unification. Let me implement this:

  1. When encountering an accessor as an argument, return a pending marker
  2. After call-site unification, resolve the pending accessor with the full type
  3. Create the correct SpecId
