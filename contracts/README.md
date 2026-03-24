# Contract Template

Template for creating new smart contract projects.

This project is meant to be used as a templated during the creation of new Github repositories (will show in the `Create a new repository > Configuration > Start with a template` selector).

It will contain some useful configuration files and scripts, that can be used also with existing projects (manually copied).


## Usage

### Build

```shell
forge build
```

### Test

```shell
forge test
```

### Format

```shell
forge fmt
```

### Gas Snapshots

```shell
forge snapshot
```

### Deploy

```shell
forge script script/Counter.s.sol:CounterScript --rpc-url <your_rpc_url> --private-key <your_private_key>
```

## New project creation checklist

The following operations need to be performed after this repository has been created.

- [ ] In GitHub repo settings:
    - [ ] Add a new ruleset called "Protected branches" and include the following changes:
        - Enforcement status: active
        - Target branches: Include default branch
        - Require linear history
        - Require a pull request before merging
          - Required approvals: 1
          - Allowed merge methods: Squash
        - Block force pushes
    - [ ] In General → Features → Pull requests:
        - Select "Pull request title and description" in "Default commit message" option
        - Unckeck "Allow merge commits" option
        - Check "Allow auto-merge" option
- [ ] Run `forge install` to install the dependencies. This will create a new `foundry.lock` file which you should commit to the project
- [ ] Once all entries in this list are checked, delete this section from the readme