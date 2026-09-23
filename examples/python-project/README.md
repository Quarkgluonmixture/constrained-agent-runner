# gpt-loop example Python project

A deliberately tiny fixture project. gpt-loop's regression suite and end-to-end
acceptance runs point at this workspace so the control plane can be exercised
without touching a real project.

It is registered in `projects.json` as `example-python` and uses the
`example-python` profile, which adds fixture actions (`always_fails`,
`not_applicable`, `large_output`, `hang`) on top of the normal `python` profile.

Real projects should use the `python` profile instead.
