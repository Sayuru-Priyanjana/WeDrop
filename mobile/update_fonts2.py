import os
import re

def process_file(path):
    with open(path, 'r', encoding='utf-8') as f:
        content = f.read()

    def replacer(match):
        val = float(match.group(1))
        # If font size is between 11 and 15, reduce by 2
        if 11 <= val < 16:
            new_val = val - 2
            if new_val == int(new_val):
                new_val = int(new_val)
            return f"fontSize: {new_val}"
        # If it's already small, maybe reduce by 1
        elif 9 <= val < 11:
            new_val = val - 1
            if new_val == int(new_val):
                new_val = int(new_val)
            return f"fontSize: {new_val}"
        return match.group(0)

    new_content = re.sub(r'fontSize:\s*([\d.]+)', replacer, content)

    with open(path, 'w', encoding='utf-8') as f:
        f.write(new_content)

process_file('lib/ui/widgets.dart')
process_file('lib/ui/theme.dart')
print("Done updating widgets.dart and theme.dart")
