# Step 2 — Your first recipe

A **recipe** is a small declarative file that tells `rev-stealth` how to
extract structured data from a site. Recipes live in
`~/.config/rev-stealth/recipes/<site>.toml` and can be proposed by the CLI
itself for a one-shot URL.

## Propose a recipe for an arbitrary URL

```sh
rev-stealth recipe propose-endpoint \
  --url https://example.com/products \
  --output-format json \
  --dry-run
```

`--dry-run` shows the recipe the CLI would write without actually touching
the filesystem. Remove `--dry-run` to commit it.

## List & inspect

```sh
rev-stealth recipe list --output-format json | jq '.recipes[].name'
rev-stealth recipe show --name example_com
```

## Run a spider against the recipe

```sh
rev-stealth spider --recipe example_com --output-format json > out.json
jq '.items | length' out.json
```

## Smoke test

```sh
rev-stealth recipe list --output-format json | jq '.recipes | length' | grep -q '^[1-9]'
# expected: exit 0 (at least one recipe present)
```
