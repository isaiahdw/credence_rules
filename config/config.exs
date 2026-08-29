import Config

# Dogfood config — only loaded when running `mix credence.check` from
# THIS repo. Library consumers don't see this file; they configure
# their own per-rule opts in their own `config/`.
#
# This project takes its own "every exception requires a comment"
# stance literally: there are NO rule carve-outs here. Each genuine
# exception is documented inline at the code with a
# `# credence-file:<rule> — <reason>` directive (whole-file) or a
# `# credence:<rule> — <reason>` directive (single line). See
# `CredenceRules.Suppression`.
