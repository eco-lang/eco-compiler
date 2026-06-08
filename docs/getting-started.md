# Installation

On Debian based systems you can install the .deb release.
This will install eco to /usr/local/bin:

    sudo dpkg --install eco_0.1.0-RC2_amd64.deb

On other systems or if you want a local install, you can unpack the .zip or .tar.gz relase.
Unpack it into `/usr/local/` or some other place. For the purposes of this guide, we will assume
you unpacked into `/usr/local/` so adjust paths as necessary.

# Run an example

In the distribution there is a `/share/eco/examples` folder. 

Copy that folder to your home dir so you have write access and can build there. Lets build 
and run the hello world example:

    cp -R /usr/local/share/eco/examples ~/
    cd ~/examples/hello
    eco make src/Hello.elm --output=hello

Run it:

    ./hello
