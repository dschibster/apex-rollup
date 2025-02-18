# Contributions Welcome

If you'd like to submit a contribution to `Rollup`, please do!

Before doing work on `apex-rollup`, be sure to install the dependencies:

- `npm i` or `yarn`
- `sfdx plugins:install @salesforce/sfdx-scanner`

When submitting a pull request, please follow these guidelines:

- there should be no errors when running `npm run scan` or `yarn scan`
- ensure your dependencies have been installed and that any/all file(s) changed have had prettier-apex run on them (usually as simple as enabling "Format On Save" in your editor's options); alternatively you can always format the document in Vs Code using `Shift + Ctrl + F` or `cmd + Shift + F` once you're done writing. Your mileage may vary as to the hotkey if you're using Illuminated Cloud or another text editor; you always have the option of invoking prettier on the command-line
- ensure that tests have been run against a scratch org. You can use `sfdx force:org:display --verbose` to get the `Sfdx Auth Url` for the org you're developing against - just store the value of that in a text file named `DEVHUB_SFDX_URL.txt` in the root directory of this repo (it's Git ignored; you'll never commit your credentials or expose them in any way). After that, validating that everything is working correctly is as simple as running the included `scripts/test.sh` script, or `scripts/test.ps1` if you're on a Windows machine.
- ensure that any change to production code comes with the addition of tests. It's possible that I will accept PRs where _only_ production-level code is changed, if an optimization is put in place -- but otherwise, try to write a failing test first!
- there is another directory, `extra-tests`, included to provide code coverage for the accessing of custom fields linked as Field Definitions within `Rollup__mdt`, as well as complicated DML operations and CMDT-specific tests. You should add `extra-tests` temporarily to your `sfdx-project.json`'s `packageAliases` property in order to deploy those test classes and their dependencies. The reason these are optional test(s) is because they rely on custom fields, which I do not want anybody to have to install in their own orgs beyond what is necessary. You can browse the powershell test script located in `scripts/test.ps1` to see how the CI system swaps out the existing `sfdx-project.json` on deploy with the one located in the `scripts/` directory to ensure that tests requiring custom fields pass on a scratch org prior to a build passing. The `README` also includes additional context under the "Contributing" section related to validating all `Rollup` tests pass locally prior to submitting a PR