echo "Copying key bindings to ~/Library/KeyBindings"
mkdir -p ~/Library/KeyBindings/
cp DefaultKeyBinding.dict ~/Library/KeyBindings/

echo "Copying key xcode colour scheme to ~/Library/Developer/Xcode/UserData/FontAndColorThemes"
mkdir -p ~/Library/Developer/Xcode/UserData/FontAndColorThemes
cp Kayru.dvtcolortheme ~/Library/Developer/Xcode/UserData/FontAndColorThemes
