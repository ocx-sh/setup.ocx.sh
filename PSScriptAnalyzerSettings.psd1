@{
    # PSScriptAnalyzer settings for pwsh/install.ps1.
    #
    # install.ps1 is a SINGLE-FILE installer script, not a module exporting
    # cmdlets. Its functions (Say, Err, Warn, Download-File, Verify-Checksum,
    # Detect-Architecture, ...) are PRIVATE helpers used only within the file —
    # they are never imported, never invoked by an external caller, and never
    # part of a public surface. The canonical reference installer
    # (ocx.sh/install.ps1) uses the exact same private-function verb/noun style.
    #
    # The three rules excluded below are STYLISTIC conventions for SHIPPED
    # cmdlets/modules. They do not apply to a self-contained script and the
    # canon installer trips them too, so excluding them keeps parity with canon
    # while leaving every correctness/security rule (Warning + Error severity)
    # fully enforced:
    #
    #   PSUseApprovedVerbs                       Helpers use plain, descriptive
    #                                            verbs (Detect-, Verify-,
    #                                            Download-, Create-, Modify-,
    #                                            Print-) that read clearly in a
    #                                            script but are not on the
    #                                            approved-verb list for exported
    #                                            cmdlets.
    #   PSUseSingularNouns                       Same private helpers; nouns are
    #                                            chosen for readability, not the
    #                                            cmdlet-noun singular convention.
    #   PSUseShouldProcessForStateChangingFunctions
    #                                            New-/Set-/Remove- style helpers
    #                                            mutate local install state; an
    #                                            installer is not a reusable
    #                                            cmdlet and -WhatIf/-Confirm
    #                                            plumbing would add no value.
    #
    # Everything else (empty catch blocks, unused params, BOM/encoding, plaintext
    # secrets, positional-parameter hazards, etc.) stays ON.
    ExcludeRules = @(
        'PSUseApprovedVerbs',
        'PSUseSingularNouns',
        'PSUseShouldProcessForStateChangingFunctions'
    )
}
