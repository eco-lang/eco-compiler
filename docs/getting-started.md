# Installation

On Debian based systems you can install the .deb release.
This will install eco to /usr/local/bin:

    sudo dpkg --install eco_0.1.0-RC2_amd64.deb

On other systems or if you want a local install, you can unpack the .zip or .tar.gz relase.
For example you could unpack it in your home directory:

    mkdir eco
    cd eco
    unzip eco-0.1.0-RC2-x86_64-linux-musl.zip

Then add the ~/eco/bin directory to your PATH.

# Run an example

In the distribution there is a /share/eco/examples folder. Either cd to that folder or if 
you installed system wide with the .deb package, you could copy that folder to your home dir.
Then build and run the hello world example:

    cp -R /usr/local/share/eco/examples .
    cd examples/hello
    eco make src/Hello.elm \
      --local-package=eco-kernel=/usr/local/share/eco/kernel/eco-kernel-cpp/ \
      --output=hello

Run it:

    ./hello
