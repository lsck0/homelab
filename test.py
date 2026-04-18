with open('src/instances/main.tf', 'r') as f:
    tf = f.read()

# Replace dhcp with static IP for router
tf = tf.replace('each.value.type == "router" ? "dhcp" :', 'each.value.type == "router" ? "192.168.178.29/24" :')
tf = tf.replace('each.value.type == "router" ? null :', 'each.value.type == "router" ? "192.168.178.1" :')

with open('src/instances/main.tf', 'w') as f:
    f.write(tf)
