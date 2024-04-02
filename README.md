# Why create this repo?
The Enterprise Edition's data plane is built on the open source Apache APISIX 3.2(we will review regularly to see if it is necessary to upgrade to a newer Apache APISIX version), but with some differences:
- The admin API is closed by default (when a customer doesn't want to use our control plane, we can enable the admin API in data plane's yaml configure file)
- Plug-ins exclusive of Enterprise Edition
- Backwards compatibility for bugfixes and security vulnerabilities
- Backward compatibility of valuable new features
- Bugs reported by customers will be fixed in the enterprise version first, and then contributed to Apache APISIX
- Delivery images are automatically scanned for security vulnerabilities on Google Cloud
  
# How does this repo work?

This code repository is built based on Apache APISIX 3.2. If you want to synchronize a bugfix or new feature from a new version of Apache APISIX (such as 3.8) to this repository, you need to understand its implementation mechanism and how it works:
- When packaging and building, the complete code and test cases will be pulled from Apache APISIX 3.2. If the same file is found in this repo (the path and file name are consistent), the file in this repo will be used to replace the file in the open-source version; if the file does not exist in this repo, the file in the open source version will prevail.
- This code repository does not use the usual `diff` to handle the code differences between the enterprise edition and the open source edition, but uses code file level substitution. This is to allow developers to better read and understand the code of the enterprise version data plane.
- In order to ensure compatibility with the open source Apache APISIX and the quality of new code, CI will completely run all test cases of Apache APISIX
- For bugfixes and new features picked from the new version of Apache APISIX cherry, in addition to code and documentation, **test cases must also be added**

# What is in this repo?
- Enterprise Edition Data Plane
- Plug-ins exclusive of Enterprise Edition
- Bugfixes, and new features that are backward compatible with new versions of Apache APISIX
- Workaround for undisclosed security vulnerability
- Security enhancement
  
# What will not be included in Enterprise Edition DP?
- Changes to the underlying implementation of Apache APISIX, such as routing matching algorithms, load balancing algorithms, health checks, etc. We hope these are consistent with the open source Apache APISIX because there are wider usage scenarios and large-scale verification in the community
- Bugfix for open source plug-ins for the same reason as above
- Publicly disclosed security vulnerabilities
