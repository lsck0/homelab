import re

with open("src/instances/300-router.nix", "r") as f:
    content = f.read()

# Add dot to zone names to make them absolute
content = content.replace("internal {", "internal. {")
content = content.replace("external {", "external. {")

with open("src/instances/300-router.nix", "w") as f:
    f.write(content)
