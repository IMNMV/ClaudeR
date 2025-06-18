# ClaudeR Installation Guide for AI Agents

This guide provides explicit instructions for installing the ClaudeR package and its dependencies.

## Prerequisites

The target environment must have:
1.  R (version 4.0 or later) installed.
2.  Python (version 3.8 or later) installed and available in the system's PATH.
3.  The `devtools` R package installed. If not present, it can be installed by running `install.packages("devtools")` in R.

## Installation Steps

Execute the following commands in an R environment in order.

### Step 1: Install the ClaudeR Package from GitHub

```R
devtools::install_github("IMNMV/ClaudeR")
```


### Step 2: Run the Automated Setup Function

```R
# Load the library
library(ClaudeR)
# The function will automatically detect the OS and the default Python executable.
install_clauder()
```
