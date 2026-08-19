# Releasing

This repository has two release tracks.

| Track | Tag pattern | Workflow | Result |
|---|---|---|---|
| GitHub Action | `vX.Y.Z` | `.github/workflows/release.yml` | A GitHub release and a moving `vX` alias |
| Jenkins plugin | `jenkins-plugin-vX.Y.Z` | `.github/workflows/jenkins-plugin.yml` | Signed `.hpi` files on that release |

The two tracks are independent. The Jenkins plugin is a binary file that you
install. The action is source code that GitHub reads at `uses:` time. A plugin
release does not make an action release.

## How to make an action release

```bash
git checkout main && git pull
# In CHANGELOG.md, move the [Unreleased] items to a new [X.Y.Z] heading.
# Add the link at the end of the file.
git commit -am "chore: release vX.Y.Z"   # Use a pull request.
git tag -s vX.Y.Z -m "vX.Y.Z"            # -s signs the tag.
git push origin vX.Y.Z
```

The tag starts `release.yml`. The workflow does these four steps:

1. It makes sure that the tag is on `main`. If the tag is not on `main`, the
   workflow stops. This prevents a release from unreviewed code.
2. It makes sure that the release tree has all the consumer files. These files
   are the two `action.yml` files, `workflows/_shared/lib/ci.sh`, and the three
   engine entry points. GitHub reads these files in the consumer job. If a file
   is absent, the consumer job fails. This step finds the error first.
3. It makes the GitHub release. The release notes tell how to pin the action.
4. It moves the `vX` alias to the same commit. The workflow does not move the
   alias for a pre-release. Thus `@v1` always points to the newest stable
   1.x release.

## Which reference to pin

The repository supports all three references below. Select one reference.

- **`@<40-char-sha>`**. This reference does not change. Your workflow runs the
  same code until you change the SHA in a pull request. Use this reference for
  a repository with high security requirements. Refer to
  [security.md](security.md).
- **`@vX`**, for example `@v1`. This alias points to the newest stable `X.Y.Z`
  release. New releases come to your repository automatically. You do not make
  a pull request. Use this alias for a pilot repository.
- **`@vX.Y.Z`**. This reference does not change, and it is easy to read. This
  workflow does not move a patch tag.

A moving alias has a cost. A person who can push the `v1` tag can change the
code that all `@v1` consumers run. For this reason, the workflow moves `vX`
only from a commit that is on `main`. Also, you must protect the `v*` tags.

## Necessary tag protection

The workflow must be able to move `vX`. No person must be able to move
`vX.Y.Z`. Make a ruleset for `v*` tags that does these three things:

- It prevents tag deletion for all users.
- It prevents changes to `vX.Y.Z` tags.
- It permits the `GITHUB_TOKEN` of this workflow to change the `vX` alias.

Without this ruleset, the alias is only as safe as the weakest push credential
on the repository.

## Version numbers

Three items are visible to the consumer. These items are the action inputs and
outputs, the engine command-line flags, and the format of the comment.

- **Major**. You remove an input. You give an input a new function. You change
  a default value and the behavior changes. You remove a provider.
- **Minor**. You add an input, a provider, a workflow, or a skill rule.
- **Patch**. You correct a fault, and all inputs keep their function.

Be careful with changes to the prompts and the rules. These changes can change
the results of the classifier, but the inputs and outputs stay the same. If new
rules change the results, use a minor version at minimum. Record the change in
CHANGELOG.md.
