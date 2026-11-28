"""Parse every Jinja template in a Home Assistant configuration.yaml.

Home Assistant's check_config does not fully parse templates in scripts and
automations, so a syntax error (a template nested in another's braces) only
shows when the script loads. Every string containing {{ or {% is parsed
here; one that does not parse fails the check, naming its path.
"""

import sys

import jinja2
import yaml


class Loader(yaml.SafeLoader):
    pass


# !secret, !include and the like: their values are not templates.
Loader.add_multi_constructor("!", lambda loader, suffix, node: None)


def walk(value, path, errors, env):
    if isinstance(value, dict):
        for key, item in value.items():
            walk(item, f"{path}.{key}", errors, env)
    elif isinstance(value, list):
        for index, item in enumerate(value):
            walk(item, f"{path}[{index}]", errors, env)
    elif isinstance(value, str) and ("{{" in value or "{%" in value):
        try:
            env.parse(value)
        except jinja2.TemplateSyntaxError as err:
            errors.append(f"{path}: {err.message}: {value!r}")


def main():
    with open(sys.argv[1]) as f:
        config = yaml.load(f, Loader=Loader)
    env = jinja2.Environment(extensions=["jinja2.ext.loopcontrols", "jinja2.ext.do"])
    errors = []
    walk(config, "", errors, env)
    for error in errors:
        print(error)
    print(f"{len(errors)} template errors")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
