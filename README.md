<h1 style="color: #d9a94b;">LH Fishing</h1>

<p>Fish with Space and keep your catches, prices and fishing history in one compact window.</p>

<p>LH Fishing opens when you equip a fishing pole and closes when you switch to another weapon. The window uses the same border as LH ExpBar, starts unlocked for dragging and grows with the number of items shown.</p>

<h2 style="color: #73c9c4;">What it does</h2>

<ul>
  <li>Press <strong>Space</strong> to cast and to interact with your bobber. Press Space again within two seconds of casting to reposition the bobber. <strong>Shift+Space</strong> jumps while the pole is equipped.</li>
  <li>Automatically loots fishing catches and lists every item caught. Hover over a row for the normal item tooltip.</li>
  <li>Flashes the updated quantity and its background once over one second when you catch an item.</li>
  <li>Starts a new session when you equip a fishing pole. The large gold timer starts with that session's first cast and stops when you unequip the pole.</li>
  <li>Shows <strong>Session</strong> catches, <strong>History here</strong> from earlier sessions in the current area, and <strong>History overall</strong> across all recorded areas.</li>
  <li>Shows item counts and catch percentages for the selected tab. The current session's percentages use only that session's catches.</li>
  <li>Shows each item's most common fishing area across the saved history in all three tabs, including its subzone when available.</li>
  <li>Rows start sorted by quantity, highest first. Click a column heading to sort its rows; click it again to reverse the order. Switching tabs restores the default sort.</li>
  <li>Shows Auctionator auction prices for each item and their totals in all three tabs, plus estimated auction value per hour. Missing auction prices appear as a dash.</li>
</ul>

<h2 style="color: #c78be6;">Fishing and lures</h2>

<p>Open <strong>Options &rarr; AddOns &rarr; LH Tweaks &rarr; LH Fishing</strong>. <strong>Apply best lure automatically</strong> is on by default. If your pole has no lure and you have a usable one in your bags, the first Space press applies the strongest available lure; press Space again to cast. The window shows the active lure's fishing bonus in light blue, plus its name when known and its remaining time when available. With automatic lure application enabled, a gold reminder appears only when no lure is attached and none is in your bags. Turn the option off to cast without automatic lure application.</p>

<p>While your line is out, Space interacts with your bobber when it is the game's interaction target. If the game reports that no fish are hooked, the next Space press is ready to cast again. WoW requires a new key press for a new cast after that message.</p>

<h2 style="color: #c78be6;">Window and history</h2>

<p>Drag the unlocked window to move it; <strong>Lock fishing window</strong> prevents dragging. <strong>Reset position</strong> returns it to the screen center. The current area and its last fishing time appear below the title. A session ends when you unequip the pole; equipping it again starts an empty new session. Earlier catches remain under <strong>History here</strong> and <strong>History overall</strong>. Fishing history, session records and settings are saved per character.</p>

<p>Click the left arrow beside the timer to switch to Compact Mode. It keeps the timer and lure status visible while the window shrinks from its right edge; the upper-left corner stays fixed. Click the right arrow to restore the full window. The mode is saved per character.</p>

<p><strong>Reset history</strong> in the LH Fishing settings asks for confirmation before deleting this character's saved catches, sessions and area history. It keeps the window position and fishing settings.</p>

<h2 style="color: #c78be6;">Settings profiles</h2>

<p>Use <strong>Use settings from</strong> to copy another character's window position, lock state, display mode and automatic lure setting. Configure that character and log out before choosing it as a source. LH Tweaks can apply its source character to all LH companion addons. Catch and session history remain separate for each character.</p>

<h2 style="color: #73c9c4;">More LH addons</h2>

<p>Choose only the pieces you want. LH Fishing and most companion addons require LH Tweaks.</p>

<ul>
  <li><strong>LH ExpBar:</strong> A minimal experience bar with rested XP.</li>
  <li><strong>LH Skills:</strong> Profession ranks in a movable compact bar.</li>
  <li><strong>LH Socials:</strong> A compact guild and friends roster.</li>
  <li><strong>LH Stats:</strong> Money, free bag slots and remaining ammo below the minimap.</li>
  <li><strong>LH Tweaks:</strong> The shared settings hub and UI tweaks.</li>
</ul>

<h2 style="color: #d9a94b;">Installation and feedback</h2>

<p><strong>LH Tweaks is required.</strong> Install the LH Fishing folder beside LH Tweaks in <code>Interface/AddOns</code> and restart the game. Auctionator is optional for auction prices. If you also use Mastercraft's Angler helper, turn that helper off so both addons do not control Space at the same time. Please report problems or suggestions in the CurseForge comments.</p>

<h2 style="color: #73c9c4;">Changelog</h2>

<p><strong>Post-release updates</strong></p>

<ul>
  <li>Flash the caught item's quantity and its background once for one second.</li>
  <li>Add a compact view with the session timer, lure status and a button to restore the full window.</li>
  <li>Show AH prices without vendor columns, add the most common fishing area with subzone, and sort any column by clicking its heading.</li>
  <li>Show the active lure's fishing bonus and remaining time, and show the missing-lure reminder only when no lure is attached.</li>
  <li>Track catches from fishing loot messages, loot slots and bag changes without counting the same catch twice.</li>
  <li>Keep catch rows visible when the client's legacy item-info API is unavailable.</li>
</ul>

<p><strong>1.0.0 - Initial release</strong></p>

<ul>
  <li>Added Space-based fishing, optional automatic lure application, session tabs and catch statistics.</li>
  <li>Added area and overall history, Auctionator and vendor values, settings profiles and a history reset button.</li>
</ul>

<hr>
<p><sup>*</sup> Implemented with the help of Codex and GPT-6-SOL. Please report anything that does not work as expected.</p>
