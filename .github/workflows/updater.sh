#!/bin/bash

#=================================================
# PACKAGE UPDATING HELPER
#=================================================

# This script is meant to be run by GitHub Actions
# The YunoHost-Apps organisation offers a template Action to run this script periodically
# Since each app is different, maintainers can adapt its contents so as to perform
# automatic actions when a new upstream release is detected.

# Remove this exit command when you are ready to run this Action
exit 1

#=================================================
# FETCHING LATEST RELEASE AND ITS ASSETS
#=================================================

# Fetching information
current_version=$(cat manifest.toml | tomlq -j '.version|split("~")[0]')
repo=$(cat manifest.toml | tomlq -j '.upstream.code|split("https://github.com/")[1]')
# Some jq magic is needed, because the latest upstream release is not always the latest version (e.g. security patches for older versions)
version=$(curl --silent "https://api.github.com/repos/$repo/releases" | jq -r '.[] | select( .prerelease != true ) | .tag_name' | sort -V | tail -1)
assets=($(curl --silent "https://api.github.com/repos/$repo/releases" | jq -r '[ .[] | select(.tag_name=="'$version'").assets[].browser_download_url ] | join(" ") | @sh' | tr -d "'"))

# Later down the script, we assume the version has only digits and dots
# Sometimes the release name starts with a "v", so let's filter it out.
# You may need more tweaks here if the upstream repository has different naming conventions. 
if [[ ${version:0:1} == "v" || ${version:0:1} == "V" ]]; then
    version=${version:1}
fi

# Setting up the environment variables
echo "Current version: $current_version"
echo "Latest release from upstream: $version"
echo "VERSION=$version" >> $GITHUB_ENV
echo "REPO=$repo" >> $GITHUB_ENV
# For the time being, let's assume the script will fail
echo "PROCEED=false" >> $GITHUB_ENV

# Proceed only if the retrieved version is greater than the current one
if ! dpkg --compare-versions "$current_version" "lt" "$version" ; then
    echo "::warning ::No new version available"
    exit 0
# Proceed only if a PR for this new version does not already exist
elif git ls-remote -q --exit-code --heads https://github.com/$GITHUB_REPOSITORY.git ci-auto-update-v$version ; then
    echo "::warning ::A branch already exists for this update"
    exit 0
fi

# As of current build process, each release should contain a unique asset (zip)
case ${#assets[@]} in    
    0) 
        echo "::warning ::no asset found, exiting"
        exit 0 
        ;;     
    1)
        echo "1 available asset, let's proceed"
        ;;
    *) 
        echo "::warning ::multiple assets, that breaks the expected pattern, exiting"
        exit 0

#=================================================
# UPDATE SOURCE FILES
#=================================================

asset_url=${assets[0]}

# Create the temporary directory
tempdir="$(mktemp -d)"

# Download sources and calculate checksum
filename=${asset_url##*/}
curl --silent -4 -L $asset_url -o "$tempdir/$filename"
checksum=$(sha256sum "$tempdir/$filename" | head -c 64)

# Update manifest' source information in manifest
old_src_main_url=$(cat manifest.toml | tomlq -j '.resources.sources.main.url')
old_src_main_sha256=$(cat manifest.toml | tomlq -j '.resources.sources.main.sha256')
sed -i "s^$old_src_main_url^$asset_url^" # use alternate sed delimiter to avoid url escaping
sed -i "s/$old_src_main_sha256/$checksum/"
## Alternative less flexible  
#sed -i "s/^\(\s*url\s\=\s\"\).*/\1$asset_url\"/" 
#sed -i "s/^\(\s*sha256\s\=\s\"\).*/\1$checksum\"/"
## Alternative loosing manifest original's format (especially indentation) as yq currently does not apply automatic styling for toml, cf. https://github.com/kislyuk/yq/issues/164
#cat manifest.toml | tomlq -t --arg url "$asset_url" --arg sha256 "$checksum" '.resources.sources.main.url |= $url | .resources.sources.main.sha256 |= $sha256' > $tempdir/manifest.toml 
#mv $tempdir/manifest.toml manifest.toml

# Delete temporary directory
rm -rf $tempdir

else
echo "... asset ignored"
fi

done

#=================================================
# SPECIFIC UPDATE STEPS
#=================================================

# Any action on the app's source code can be done.
# The GitHub Action workflow takes care of committing all changes after this script ends.

# Update nginx.conf index page
sed -i "s/^\s*index\sCyberChef.*/\  index CyberChef_v$version.html;/" conf/nginx.conf

#=================================================
# GENERIC FINALIZATION
#=================================================

# Replace new version in manifest
sed -i "s/^version\s*=.*/version = \"$version~ynh1\"/" manifest.toml

# No need to update the README, yunohost-bot takes care of it

# The Action will proceed only if the PROCEED environment variable is set to true
echo "PROCEED=true" >> $GITHUB_ENV
exit 0
