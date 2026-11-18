# Lib: EditMode

## [19](https://github.com/p3lim-wow/LibEditMode/tree/19) (2026-11-03)
[Full Changelog](https://github.com/p3lim-wow/LibEditMode/commits/19) [Previous Releases](https://github.com/p3lim-wow/LibEditMode/releases)

- Bump version  
- Update Interface version (#88)  
    Co-authored-by: p3lim <26496+p3lim@users.noreply.github.com>  
- Add position dialog (#89)  
- Bump version  
- Further fixes for extra base layouts  
    Made it a little easier to extend should that be necessary in the future  
- Bump version  
- Damnit  
- Bump version  
- Gotta fix it anyways..  
- Don't break my script  
- Limit where it can load when unembedded  
- Account for gamepad stock layout on Forever  
- Update Interface version (#87)  
    Co-authored-by: p3lim <26496+p3lim@users.noreply.github.com>  
- Update TOC for all flavors that has edit mode  
- Bump actions/checkout from 6 to 7 (#84)  
    Bumps [actions/checkout](https://github.com/actions/checkout) from 6 to 7.  
    - [Release notes](https://github.com/actions/checkout/releases)  
    - [Changelog](https://github.com/actions/checkout/blob/main/CHANGELOG.md)  
    - [Commits](https://github.com/actions/checkout/compare/v6...v7)  
    ---  
    updated-dependencies:  
    - dependency-name: actions/checkout  
      dependency-version: '7'  
      dependency-type: direct:production  
      update-type: version-update:semver-major  
    ...  
    Signed-off-by: dependabot[bot] <support@github.com>  
    Co-authored-by: dependabot[bot] <49699333+dependabot[bot]@users.noreply.github.com>  
- Update Interface version (#85)  
    Co-authored-by: p3lim <26496+p3lim@users.noreply.github.com>  
- Refresh selection  
    Fixes #86  
- Update Interface version (#83)  
    Co-authored-by: p3lim <26496+p3lim@users.noreply.github.com>  
- Bump actions/upload-artifact from 6 to 7 (#82)  
    Bumps [actions/upload-artifact](https://github.com/actions/upload-artifact) from 6 to 7.  
    - [Release notes](https://github.com/actions/upload-artifact/releases)  
    - [Commits](https://github.com/actions/upload-artifact/compare/v6...v7)  
    ---  
    updated-dependencies:  
    - dependency-name: actions/upload-artifact  
      dependency-version: '7'  
      dependency-type: direct:production  
      update-type: version-update:semver-major  
    ...  
    Signed-off-by: dependabot[bot] <support@github.com>  
    Co-authored-by: dependabot[bot] <49699333+dependabot[bot]@users.noreply.github.com>  
- Update Interface version (#81)  
    Co-authored-by: p3lim <26496+p3lim@users.noreply.github.com>  
- Bump version  
- Make LibStub optional  
- Only call :Layout() when frames are shown (#79)  
    * Only call :Layout() when dialog is shown  
    * Only call :Layout() when extension is shown  
- Support callable values for dropdowns  
- Bump version  
- Wrong place  
- Announce and react to external resets  
- Propagate mouse motion events on checkboxes (#78)  
- Try to prevent old hooks and events from running  
- Update docs  
- More adjustments  
- Touchups  
- Divider adjustments and label hiding (#76)  
    * Fix divider alignment  
    * Add .hideLabel option to divider  
    * Adjust divider's font  
    All elements use GameFontHighlightMedium, GameFontHighlightLarge is only  
    used by the header.  
    ---------  
    Co-authored-by: Adrian L Lange <p3lim@users.noreply.github.com>  
- Add widget state refreshing and expander widget (#74)  
    * Add widget state refreshing  
    * Lint  
    * Styling  
    * Styling  
    * Add expander widget  
    * Fix alignment  
- Update Interface version (#72)  
    Co-authored-by: p3lim <26496+p3lim@users.noreply.github.com>  
- Bump version  
- Remove mainline requirement on TOC  
- Apparently TBC has Edit Mode  
- :lipstick:  
- Provide example for callbacks  
- :lipstick:  
- Adjust docs with links for system enums  
- Fix post-rename update  
- Provide the source layout name when copying  
    Fixes #67  
- Rework callback triggers  
    There were some issues with the previous logic, this should fix all of  
    those and document how they all work (kinda)  
- Adjust docs for subSystemID  
- Add support for subsystems (#71)  
    * Add support for subsystems  
    * Add missing args  
    * Update docs  
- Reset dialog when closing  
    Fixes #68  
- Check if dialog exists (#70)  
- Update license (#69)  
    Co-authored-by: p3lim <26496+p3lim@users.noreply.github.com>  
- Bump version  
- Bump peter-evans/create-pull-request from 7 to 8 (#64)  
    Bumps [peter-evans/create-pull-request](https://github.com/peter-evans/create-pull-request) from 7 to 8.  
    - [Release notes](https://github.com/peter-evans/create-pull-request/releases)  
    - [Commits](https://github.com/peter-evans/create-pull-request/compare/v7...v8)  
    ---  
    updated-dependencies:  
    - dependency-name: peter-evans/create-pull-request  
      dependency-version: '8'  
      dependency-type: direct:production  
      update-type: version-update:semver-major  
    ...  
    Signed-off-by: dependabot[bot] <support@github.com>  
    Co-authored-by: dependabot[bot] <49699333+dependabot[bot]@users.noreply.github.com>  
- Bump actions/upload-artifact from 5 to 6 (#63)  
    Bumps [actions/upload-artifact](https://github.com/actions/upload-artifact) from 5 to 6.  
    - [Release notes](https://github.com/actions/upload-artifact/releases)  
    - [Commits](https://github.com/actions/upload-artifact/compare/v5...v6)  
    ---  
    updated-dependencies:  
    - dependency-name: actions/upload-artifact  
      dependency-version: '6'  
      dependency-type: direct:production  
      update-type: version-update:semver-major  
    ...  
    Signed-off-by: dependabot[bot] <support@github.com>  
    Co-authored-by: dependabot[bot] <49699333+dependabot[bot]@users.noreply.github.com>  
- Consistent type  
- Indicate to setter that it's a reset  
    Fixes #62  
- Trigger callbacks before updating dialog  
    Otherwise the consumer hasn't had the time to create savedvariables yet  
- Need to pass through the selection  
- Update Interface version (#57)  
    Co-authored-by: p3lim <26496+p3lim@users.noreply.github.com>  
- Add a dialog refresh method  
    Fixes #59  
- Ensure we have a dialog first  
- Update dialog on layout changes  
    Fixes #60  
- Fix opacity not being stored correctly  
    Fixes #61  
- Bump version  
- Rethink how we allow multi-select dropdowns  
    Ref #56  
- Lint  
- Fix doc links  
- Add option to disable settings, with accompanying functions  
- Support non-radio correctly  
    Fixes #56  
- Add color picker support  
    Fixes #53  
- Support fine editing for slider  
    Fixes #52  
- Bump actions/checkout from 5 to 6 (#51)  
    Bumps [actions/checkout](https://github.com/actions/checkout) from 5 to 6.  
    - [Release notes](https://github.com/actions/checkout/releases)  
    - [Changelog](https://github.com/actions/checkout/blob/main/CHANGELOG.md)  
    - [Commits](https://github.com/actions/checkout/compare/v5...v6)  
    ---  
    updated-dependencies:  
    - dependency-name: actions/checkout  
      dependency-version: '6'  
      dependency-type: direct:production  
      update-type: version-update:semver-major  
    ...  
    Signed-off-by: dependabot[bot] <support@github.com>  
    Co-authored-by: dependabot[bot] <49699333+dependabot[bot]@users.noreply.github.com>  
- Lint  
- Add description tooltip support  
    This is beyond what blizzard supports, but it's nice to have  
- Update wiki on tags only  
- Rename tags workflow  
- Reset dialog predictably  
    Fixes #5  
- Don't figure callbacks early  
- Update cache whenever the layouts change  
    It's not guaranteed to be on ADDON\_LOADED  
- Don't throw errors with missing layouts  
    This actually kills the init process of the entire library  
- Different table structure  
- Use cache when querying layout names  
    C\_EditMode.GetLayouts() requires pulling data from the server, which  
    causes a freeze every time it's called (based on latency)  
- Fix error on early loading  
- Specs can trigger layout changes  
    Ref https://github.com/Gethe/wow-ui-source/blob/cbd9586890ae30fd5bdfb2f87533f3c35877ef9a/Interface/AddOns/Blizzard\_EditMode/Mainline/EditModeManager.lua#L181C19-L187  
    Fixes #47  
- Fix regression  
    Fixes #48  
- Try to run layout callback on registration (#46)  
- Lint  
- Trigger layout callbacks when frames are added  
    Otherwise it's rather cumbersome to deal with updates.  
- Add callbacks for create, rename and delete  
    Fixes #45  
- Pass layout index of the changed layout  
    Fixes #45  
- Don't get in the way  
- :lipstick:  
- Prevent clicking through the extension dialog  
- Keep extension static (#44)  
- Add docs for #43  
- Split entry's name and value (#43)  
- Manually fetch layout info (#42)  
- Better handling of system names  
- Don't waste minutes  
- :lipstick:  
- :lipstick:  
