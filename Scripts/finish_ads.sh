#!/bin/bash
set -e

# Wait for task 735 to finish
echo "Waiting for regenerate-screenshots.sh to finish..."
while pgrep -f "regenerate-screenshots.sh" > /dev/null; do
    sleep 5
done

# Run frame-screenshots.py
echo "Running frame-screenshots.py..."
python3 /Users/adriangutierrez/Documents/Github/softwarebygl-website/scripts/frame-screenshots.py

# Run generate_all_ads.py
echo "Running generate_all_ads.py..."
python3 generate_all_ads.py

# Rename iPad stripe ad
echo "Renaming iPad stripe ad..."
mv ~/Desktop/AppStoreAds/AD_ipad_ipad-get-paid-light.png ~/Desktop/AppStoreAds/AD-ipad-stripe.png || true

# Restore test skip
echo "Restoring test skip..."
python3 -c "import json; data=json.load(open('AllUnitAndUITests.xctestplan')); data['testTargets'][1]['skippedTests']=[{'targetName':'GLSmallBusinessUITests', 'testName':'MarketingShotsUITests'}]; json.dump(data, open('AllUnitAndUITests.xctestplan', 'w'), indent=2)"

echo "Done!"
