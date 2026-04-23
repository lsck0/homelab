do a codereview/refactor and make sure the following features are implemented:

- create a secrets folder (currently called keys) which will contain all generated secrets, that means authentik admin login, wireguard private key, taskserver credentials etc.
- have forgejo use authentik to login
- complete the example: rust project using sscache to compile, hosted on forgejo, using runner to build to container hub and a docker compose to run the image from the container hub
- look for any problems and fix them.
