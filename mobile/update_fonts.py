import re
import os

def update_file(path):
    with open(path, 'r', encoding='utf-8') as f:
        content = f.read()
        
    def replacer(match):
        prefix = match.group(1)
        val = float(match.group(2))
        
        # Don't touch 16 if it's right after 'My ecosystem' or 'Nearby'
        # Actually, let's just use string replacement for the specific lines to be safe.
        pass
        
    # We will just do a simpler targeted string replacement
    replacements = [
        # screens.dart headers
        ("Text(\n                        'Devices that trust each other and\\nsync automatically.',\n                        style: TextStyle(fontSize: 14", "Text(\n                        'Devices that trust each other and\\nsync automatically.',\n                        style: TextStyle(fontSize: 12"),
        ("Text('${paired.where((d) => d.online).length} online', style: const TextStyle(fontSize: 12", "Text('${paired.where((d) => d.online).length} online', style: const TextStyle(fontSize: 11"),
        ("style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600", "style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600"),
        ("style: TextStyle(fontSize: 14, color: WeDropColors.inkDim, height: 1.4)", "style: TextStyle(fontSize: 12, color: WeDropColors.inkDim, height: 1.4)"),
        ("Text(\n                'Other devices running WeDrop on this network.',\n                style: TextStyle(fontSize: 14", "Text(\n                'Other devices running WeDrop on this network.',\n                style: TextStyle(fontSize: 12"),
        ("Open WeDrop on your other devices", "Open WeDrop on your other devices"), # need exact match
        ("style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600", "style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600"),
        ("style: const TextStyle(fontSize: 13, color: WeDropColors.inkDim)", "style: const TextStyle(fontSize: 12, color: WeDropColors.inkDim)"),
        ("style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: WeDropColors.brand)", "style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: WeDropColors.brand)"),
        ("style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700", "style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700"),
        ("style: const TextStyle(fontSize: 12, color: WeDropColors.inkDim)", "style: const TextStyle(fontSize: 11, color: WeDropColors.inkDim)"),
        ("Text('What this device can do', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600", "Text('What this device can do', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600"),
        ("Text(label, style: const TextStyle(fontSize: 13", "Text(label, style: const TextStyle(fontSize: 12"),
        ("style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600", "style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600"),
    ]
    
    for old, new in replacements:
        content = content.replace(old, new)
        
    with open(path, 'w', encoding='utf-8') as f:
        f.write(content)

update_file('lib/ui/screens.dart')
print("Done updating screens.dart")
