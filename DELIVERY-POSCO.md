# `enterprise-delivery-p` — what this branch is

**This branch is configuration, not a feature. It is never merged into `main`.**

`release` refuses to build unless every source repo sits on the branch that
`workspace.json` pins (`Prepare-ReleaseWorkspace` → *"release source must be on
main: architect is on …"*). The POSCO build is cut from the Architect
customization branch, so the pin has to say so:

```
workspace.json   repositories[architect].branch   main → enterprise-custom-p
```

That one line is the whole difference from `main`. Nothing else here is
delivery-specific.

## Why a branch instead of editing in place

`release` also requires every source repo to be **clean**, workspace included.
An uncommitted edit to `workspace.json` fails that check. A checked-out branch
is clean, so the pin has to be committed somewhere — and it must not be `main`,
which stays generic for everyone else's builds.

## How to use it

```powershell
git -C <workspace> checkout enterprise-delivery-p
.\robo.cmd release architect-electron
```

## Keeping it current

This branch currently also carries the pdf2bpmn release changes (PR #1), because
that PR is still open and the build needs them. Once PR #1 lands on `main`:

```powershell
git checkout enterprise-delivery-p
git rebase main          # afterwards this branch should be main + the pin commit
```

If the check-out ever shows more than the pin on top of `main`, something
delivery-agnostic was committed here by mistake — move it to a PR against `main`.
