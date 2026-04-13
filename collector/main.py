##########################################################
# This RNS example demonstrates broadcasting unencrypted #
# information to any listening destinations.             #
##########################################################

import sys
import argparse
import RNS
import time
import random
import datetime
import curses
import json
import os


APP_NAME = "example_utilities"

MAX_TRANSMISSION_DELAY = 2 # max time (seconds) to wait between broadcasts
MIN_TRANSMISSION_DELAY = 0.5

OUTPUT_REFRESH_RATE = 0.5 # refresh every n seconds

transmission_history = {}
most_recent_transmissions = {}
node_location = None
node_name = None
reticulum = None



def program_setup(sc, configpath, node_name, node_location, channel=None):
    global reticulum
    reticulum = RNS.Reticulum(configpath)
    
    if channel == None:
        channel = "testingtestingtesting"

    # We create a PLAIN destination. This is an uncencrypted endpoint
    # that anyone can listen to and send information to.
    broadcast_destination = RNS.Destination(
        None,
        RNS.Destination.IN,
        RNS.Destination.PLAIN,
        APP_NAME,
        "broadcast",
        channel
    )

    broadcast_destination.set_packet_callback(packet_callback)
    mainLoop(broadcast_destination, sc)
    

def packet_callback(data, packet):
    # Simply print out the received data
    sender_name = data.decode("utf-8")
    packet_stats = {"rssi": packet.rssi, "snr": packet.snr, "time": datetime.datetime.now()}

    
    most_recent_transmissions[sender_name] = packet_stats
    if (sender_name not in list(transmission_history.keys())):
        transmission_history[sender_name] = []

    updated_stats_list = transmission_history[sender_name] + [packet_stats]
    transmission_history[sender_name] = updated_stats_list


def mainLoop(destination, sc):
    # Let the user know that everything is ready

    # We enter a loop that runs until the users exits.
    # If the user hits enter, we will send the information
    # that the user entered into the prompt.

    
    time_of_last_transmit = time.time()
    time_to_wait_between_transmissions = MIN_TRANSMISSION_DELAY + random.random() * MAX_TRANSMISSION_DELAY # time to wait between transmissions (0-2 seconds). kinda bad collision avoidance

    last_disp_update = time.time()
    sc.nodelay(1)
    while True:
    
        if ((time.time() - time_of_last_transmit) > time_to_wait_between_transmissions):
            time_of_last_transmit = time.time()
            data = node_name.encode("utf-8")
            packet  = RNS.Packet(destination, data)
            packet.send()

            node = "this node"
            if (node not in list(transmission_history.keys())):
                transmission_history[node] = []
            transmission_history[node] = transmission_history[node] + [{"transmit_time": time_of_last_transmit, "location": node_location}]

        if ((time.time() - last_disp_update) > OUTPUT_REFRESH_RATE):
            last_disp_update = time.time()
            for i, node in enumerate(most_recent_transmissions):
                age_of_transmission = (datetime.datetime.now() - most_recent_transmissions[node]['time']).total_seconds()
                sc.addstr(i * 4, 0, f"NODE: {node}")
                sc.addstr(i * 4 + 1, 2, f"RSSI: {most_recent_transmissions[node]['rssi']}")
                sc.addstr(i * 4 + 2, 2, f"SNR: {most_recent_transmissions[node]['snr']}")
                if (age_of_transmission > MAX_TRANSMISSION_DELAY * 1.3):
                    sc.addstr(i * 4 + 3, 2, f"Time Since Reception: {age_of_transmission} seconds", curses.A_STANDOUT)
                else: 
                    sc.addstr(i * 4 + 3, 2, f"Time Since Reception: {age_of_transmission} seconds")
        sc.addstr(sc.getmaxyx()[0] - 2, 0, "Press Q to SAVE results and exit")
        sc.addstr(sc.getmaxyx()[0] - 1, 0, "Ctl-C to DISCARD results and exit")
        sc.refresh()
        if (sc.getch() == ord('q')):
            save_and_exit()
        time.sleep(0.01)

def serialize_datetime(obj):
    if isinstance(obj, datetime.datetime):
        return obj.isoformat()
    raise TypeError("Type not serializable")

def save_and_exit():
    filepath = f'mesh_data_node_{node_name}.json'
    if os.path.exists(filepath):
        with open(filepath, 'r') as f:
            existing = json.load(f)
        for key, entries in transmission_history.items():
            if key in existing:
                existing[key].extend(entries)
            else:
                existing[key] = entries
        merged = existing
    else:
        merged = transmission_history
    with open(filepath, 'w') as f:
        json.dump(merged, f, default=serialize_datetime)
    print(f"Saved to {filepath}")
    sys.exit(0)






##########################################################
#### Program Startup #####################################
##########################################################

# This part of the program gets run at startup,
# and parses input from the user, and then starts
# the program.

def main(sc):
    program_setup(sc, configarg, node_name, node_location, channelarg)

if __name__ == "__main__":
    try:
        parser = argparse.ArgumentParser(
            description="Reticulum example demonstrating sending and receiving broadcasts"
        )

        parser.add_argument(
            "--config",
            action="store",
            default='./rns_config',
            help="path to alternative Reticulum config directory",
            type=str
        )

        parser.add_argument(
            "--channel",
            action="store",
            default=None,
            help="broadcast channel name",
            type=str
        )

        args = parser.parse_args()

        if args.config:
            configarg = args.config
        else:
            configarg = None

        if args.channel:
            channelarg = args.channel
        else:
            channelarg = None

        node_name = input("What is your team name? ")
        node_location = input("where is the node's location? ")

        curses.wrapper(main)

    except KeyboardInterrupt:
        print("")
        print(transmission_history)
