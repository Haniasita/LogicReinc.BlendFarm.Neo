using System;
using System.Collections.Generic;
using System.Net.Sockets;
using System.Net;
using System.Text;

namespace LogicReinc.BlendFarm.Client
{
    public class MagicPacket
    {
        public static void Send(string macAddress)
        {
            if (string.IsNullOrWhiteSpace(macAddress))
            {
                Console.WriteLine("[WARNING] Magic packet not sent: MAC address is empty or null");
                return;
            }

            // Clean up the MAC address
            macAddress = macAddress.Replace(":", "").Replace("-", "");

            if (macAddress.Length != 12)
            {
                Console.WriteLine($"[WARNING] Magic packet not sent: Invalid MAC address format '{macAddress}' (expected 12 hex characters after cleaning)");
                return;
            }

            try
            {
                // Convert MAC string to bytes
                byte[] macBytes = new byte[6];
                for (int i = 0; i < 6; i++)
                {
                    macBytes[i] = Convert.ToByte(macAddress.Substring(i * 2, 2), 16);
                }

                // Build the magic packet: 6 x 0xFF followed by 16 x MAC
                byte[] packet = new byte[102];
                for (int i = 0; i < 6; i++)
                {
                    packet[i] = 0xFF;
                }
                for (int i = 1; i <= 16; i++)
                {
                    Buffer.BlockCopy(macBytes, 0, packet, i * 6, 6);
                }

                // Send the packet via UDP broadcast
                using (UdpClient client = new UdpClient())
                {
                    client.EnableBroadcast = true;
                    client.Send(packet, packet.Length, new IPEndPoint(IPAddress.Broadcast, 9)); // Port 9 is the standard WoL port
                }

                Console.WriteLine("Magic packet sent to " + macAddress);
            }
            catch (Exception ex)
            {
                Console.WriteLine($"[WARNING] Failed to send magic packet: {ex.Message}");
            }
        }
    }
}
