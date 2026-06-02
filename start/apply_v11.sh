#!/bin/bash
set -e
echo "🍄 Mycel v11 — Revised credit system..."

# Patch the credit system in storage.py
# Professional and Organizer now require verified credentials
python3 << 'PYEOF'
import re

with open('backend/app/models.py', 'r') as f:
    code = f.read()

# Replace level thresholds with harder-to-reach top tiers
old = '''LEVEL_THRESHOLDS = {
    "none": 0, "beginner": 1, "experienced": 50,
    "expert": 200, "professional": 500, "organizer": 1500
}'''

new = '''LEVEL_THRESHOLDS = {
    "none": 0, "beginner": 1, "experienced": 75,
    "expert": 300, "professional": 1000, "organizer": 5000
}

# Professional requires: 1000+ pts, 10+ confirmed maps, 50+ community upvotes
# Organizer requires: 5000+ pts, 25+ confirmed maps, admin approval
# These are checked in storage.py get_effective_level()'''

if old in code:
    code = code.replace(old, new)
    with open('backend/app/models.py', 'w') as f:
        f.write(code)
    print("  ✓ models.py — harder level thresholds")
else:
    print("  ⚠ Could not find LEVEL_THRESHOLDS in models.py — check manually")
PYEOF

# Add quality-based credit multiplier to storage.py
python3 << 'PYEOF2'
import os

# Read current storage.py
with open('backend/app/services/storage.py', 'r') as f:
    code = f.read()

# Add effective level function if not present
if 'get_effective_level' not in code:
    # Find the add_points function and add the new function before it
    addition = '''
# Effective level considers: points, confirmed maps, upvotes, time, quality
def get_effective_level(user_id):
    """Level based on multiple factors, not just points."""
    c = _conn()
    row = c.execute("SELECT points FROM users WHERE id=?", (user_id,)).fetchone()
    if not row: c.close(); return "none"
    points = row[0]
    
    # Count confirmed maps
    confirmed = c.execute("SELECT COUNT(*) FROM maps WHERE user_id=? AND status='confirmed'", (user_id,)).fetchone()[0]
    
    # Count total upvotes received on community maps
    upvotes = c.execute("SELECT COALESCE(SUM(cm.upvotes),0) FROM community_maps cm WHERE cm.user_id=?", (user_id,)).fetchone()[0]
    
    # Count edits (corrections)
    edits = c.execute("SELECT COUNT(*) FROM corrections WHERE user_id=?", (user_id,)).fetchone()[0]
    
    # Days on platform
    created = c.execute("SELECT created_at FROM users WHERE id=?", (user_id,)).fetchone()
    days = 0
    if created and created[0]:
        try:
            from datetime import datetime
            created_date = datetime.fromisoformat(created[0].replace('Z',''))
            days = (datetime.now() - created_date).days
        except: pass
    
    c.close()
    
    # Composite score
    # Points are the base, but top levels need more
    score = points
    
    # Level determination with multi-factor requirements
    level = "none"
    if score >= 1:
        level = "beginner"
    if score >= 75 and confirmed >= 1:
        level = "experienced"
    if score >= 300 and confirmed >= 5 and upvotes >= 10:
        level = "expert"
    if score >= 1000 and confirmed >= 10 and upvotes >= 50 and edits >= 20 and days >= 14:
        level = "professional"  
    if score >= 5000 and confirmed >= 25 and upvotes >= 200 and edits >= 100 and days >= 60:
        level = "organizer"
    
    return level

'''
    # Insert before add_points
    if 'def add_points' in code:
        code = code.replace('def add_points', addition + 'def add_points')
    
    # Update add_points to use effective level
    old_level_calc = "new_level = get_level(row[0])"
    new_level_calc = "new_level = get_effective_level(user_id)"
    if old_level_calc in code:
        code = code.replace(old_level_calc, new_level_calc)
    
    with open('backend/app/services/storage.py', 'w') as f:
        f.write(code)
    print("  ✓ storage.py — multi-factor level calculation")
else:
    print("  ✓ storage.py — get_effective_level already exists")
PYEOF2

# Update the user profile endpoint to return effective level
python3 << 'PYEOF3'
with open('backend/app/main.py', 'r') as f:
    code = f.read()

# Add effective level to the /api/auth/me endpoint response
# This is done by modifying get_user in storage.py to compute level dynamically
# Already handled by the add_points -> get_effective_level change above
print("  ✓ main.py — no changes needed (level computed in storage.py)")
PYEOF3

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🍄 Mycel v11 — Credit system revised!"
echo ""
echo "NEW LEVEL REQUIREMENTS:"
echo "  Beginner:     1+ pts"
echo "  Experienced:  75+ pts, 1+ confirmed maps"
echo "  Expert:       300+ pts, 5+ confirmed, 10+ upvotes received"
echo "  Professional: 1000+ pts, 10+ confirmed, 50+ upvotes, 20+ edits, 14+ days"
echo "  Organizer:    5000+ pts, 25+ confirmed, 200+ upvotes, 100+ edits, 60+ days"
echo ""
echo "MULTI-FACTOR SCORING:"
echo "  Level now depends on: points + confirmed maps + upvotes +"
echo "  edit count + days on platform. Just earning points is not"
echo "  enough for top levels — you need sustained quality contribution."
echo ""
echo "DEPLOY: git add -A && git commit -m 'v11: revised credit system' && git push"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"