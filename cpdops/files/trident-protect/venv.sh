#!/bin/bash
python -m venv venv
source venv/bin/activate

pip install -r requirements.txt

echo
echo
echo "** Initialized venv intended for use by cpd-trident-protect.py"
echo
echo "This python virtual environment can be activated using \`source venv/bin/activate\` and deactivated using \`deactivate\`"
echo
