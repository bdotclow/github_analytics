# Github Analytics

_Placeholder readme, will add more details later_

Ruby-based scripts to pull important stats from github - intended for use by development
teams to help understand where potential bottlenecks may be.

This is mostly an internal project stored on github, so use at your own risk - some 
functionality may not be fully tested.

## Authentication

Github API key is stored in an environment variable and used for authentication to Github.

export GITHUB_API = putyourgithubkeyhere

## Usage

### Analyzing multiple repositories
Use an external file to configure repositories - create a file called repos.txt.  

One repository per line, including organization name:  **YourOrg/your-repo-name**

Execute:  rb pr_stat_analysis.rb


### Analyze one specific repository

Execute:  rb pr_stat_analysis.rb **YourOrg/your-repo-name**

### Analyze one specific PR

Execute:  rb pr_stat_analysis.rb **YourOrg/your-repo-name** **commithash**


