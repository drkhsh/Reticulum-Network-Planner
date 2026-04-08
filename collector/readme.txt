Getting set up:

So essentially all that needs to happen is:
1. make sure you have python (version 3.x) installed.

2. install rns globally as sudo (needs to be installed to whatever user will run the script. 
will require --break-system-packages on debian based distros)
- On windows you just install it with `pip install rns` in powershell or whatever.
- Note: on windows, you will also need to run `pip install windows-curses`.

3. edit the config (rns_config/config) to have the port the rnode shows up on for your system
- On windows you can look in Device Manager under `Ports (COM & LPT)`, it will show up 
as `USB Serial Device`. On my laptop it's COM5.
- On linux it will be under /dev/tty*. During testing on ubuntu it was /dev/ttyUSB0, and 
on debian it was /dev/ttyACM0

3.5. maybe also increase the transmit power in the config file as to the appropriate value 
for your board.

4. run the script either as root as a user with permissions to access the rnode over usb
- if you give your user the right permissions to access the port, all pip packages will
need to be installed to your user.
- on windows, you don't need to worry about this. just run `python main.py`





LOGISTICAL NOTES:
Since we are collecting multi-dimensional data (rssi, snr, etc) a 2D table representation
didn't make too much sense, so it currently saves data as json. Reach out to me if you want
me to put together a script to parse it and generate figures, or parse it out to multple csv
files for analysis.

The script collects the RSSI, SNR, and timestamp for each transmission from each node. 

As all communication is done as plaintext broadcasts (encryption would have required 
setting up individual links between all nodes which I didn't have time for), location
data is NOT collected for each node over communication, but the script saves the location
of the node it's running for (based on user input) and this is included in the output file.
Once all the files are collected and aggregated we will have all their locations (and for 
redundancy we have the pre-defined locations for most of them).

Pls don't put anything sketchy as your team names, as they are tranmitted in the clear.

Every team should hit Q to exit, and not ctl-c since that will not save the data to a file.
