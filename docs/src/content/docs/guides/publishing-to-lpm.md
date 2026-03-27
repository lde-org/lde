---
title: Publishing to LDE
order: 1
---

# Publishing to LDE

## How does the registry work?

The LDE registry is hosted on a GitHub repository for everyone to access and send
pull requests to.

Packages are simply links to git repositories hosted anywhere with a few bits of metadata such as package description, authors, license, etc.

## Okay, how can I upload my package?

For convenience, the `lde publish` command exists which will take the information from your `lde.json` such as name, version, description, etc and open your browser with a pre-filled pull request to the registry repository.

Then just submit it, and wait for it to be merged!

## What about updates?

The same deal here. You can simply use `lde publish` and should be able to update your package with a new version, and the registry will automatically update to the new version once it's merged.

## How's security?

Because the repository is entirely public and under scrutiny, there's not much risk of malicious packages being uploaded. If a malicious package is uploaded, it can be easily reverted and removed from the registry.

As for ownership of your own packages, technically, anyone _can_ submit a pull request to any package. Not that it will be accepted. There will be systems to ensure ownership automatically but this will be moderated manually for now regardless.

## How about doing this programmatically?

This is not currently supported, but it is on the roadmap to allow users to publish packages via the CLI without having to open a browser and submit a PR manually. This will likely be done via GitHub's API, allowing for a more seamless experience.
