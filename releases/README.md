# releases/

> [!CAUTION]
> **Generated promotion records** - do not hand-edit.

Each `v<major>.<minor>.yaml` here is the authoritative record of one release:

- the rc it was promoted from
- the exact commit that was built
- the manifest digest of every published stage

Merging a pull request that adds one **is** the promotion: the digests are re-tagged as the release, byte-identical to the candidate that was validated.

> [!CAUTION]
> The **files are immutable once merged**
> editing one is how an already-shipped version would get silently re-promoted to different bytes, so the workflows refuse modified or deleted records.  
> Hand-writing one is how you ship an image nobody tested - the schema will pass, the review is the only guard.

## Additional resources

- Schema and validation: [scripts/details/check-release-file.py](../scripts/details/check-release-file.py).
- Process: [docs/RELEASE_PROCESS.md](../docs/RELEASE_PROCESS.md).
