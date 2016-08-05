//Taken from  https://stackoverflow.com/questions/15215865/netlink-sockets-in-c-using-the-3-x-linux-kernel?lq=1

#include <linux/module.h>
#include <net/sock.h>
#include <linux/netlink.h>
#include <linux/skbuff.h>

#define NETLINK_USER 31

struct sock *nl_sk = NULL;

static void hello_nl_recv_msg(struct sk_buff *skb) {

struct nlmsghdr *nlh;
int pid;
struct sk_buff *skb_out;
int msg_size;
char *msg="Hello from kernel";
int res;

printk(KERN_INFO "Entering: %s\n", __FUNCTION__);

msg_size=strlen(msg);

nlh=(struct nlmsghdr*)skb->data;
printk(KERN_INFO "Netlink received msg payload:%s\n",(char*)nlmsg_data(nlh));
pid = nlh->nlmsg_pid; /*pid of sending process */

skb_out = nlmsg_new(msg_size,0);

if(!skb_out)
{

    printk(KERN_ERR "Failed to allocate new skb\n");
    return;

}

nlh=nlmsg_put(skb_out,0,0,NLMSG_DONE,msg_size,0);
NETLINK_CB(skb_out).dst_group = 0; /* not in mcast group */
strncpy(nlmsg_data(nlh),msg,msg_size);

res=nlmsg_unicast(nl_sk,skb_out,pid);

if(res<0)
    printk(KERN_INFO "Error while sending bak to user\n");
}

static int __init hello_init(void) {

printk("Entering: %s\n",__FUNCTION__);
//This is for 3.6 kernels and above.
struct netlink_kernel_cfg cfg = {
    .input = hello_nl_recv_msg,
};

nl_sk = netlink_kernel_create(&init_net, NETLINK_USER, &cfg);
//nl_sk = netlink_kernel_create(&init_net, NETLINK_USER, 0, hello_nl_recv_msg,NULL,THIS_MODULE);
if(!nl_sk)
{

    printk(KERN_ALERT "Error creating socket.\n");
    return -10;

}

return 0;
}

static void __exit hello_exit(void) {

printk(KERN_INFO "exiting hello module\n");
netlink_kernel_release(nl_sk);
}

module_init(hello_init); module_exit(hello_exit);

MODULE_LICENSE("GPL");
