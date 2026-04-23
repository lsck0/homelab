import re

with open("src/instances/102-internal-homepage.nix", "r") as f:
    content = f.read()

widgets_yaml = """    - greeting:
        text_size: xl
        text: Homelab
    - datetime:
        text_size: l
        format:
          dateStyle: long
          timeStyle: short
          hour12: false
    - openmeteo:
        label: Weather
        latitude: 51.23
        longitude: 6.78
        timezone: Europe/Berlin
        units: metric
    - search:
        provider: google
        target: _blank
    - resources:
        cpu: true
        memory: true
        uptime: true
        disk: /"""

content = re.sub(r'  widgetsYaml = pkgs.writeText "widgets\.yaml" \'\'.*?\'\';\n\n  bookmarksYaml', f"  widgetsYaml = pkgs.writeText \"widgets.yaml\" ''\n{widgets_yaml}\n  '';\n\n  bookmarksYaml", content, flags=re.DOTALL)

with open("src/instances/102-internal-homepage.nix", "w") as f:
    f.write(content)
