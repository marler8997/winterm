<h1>
  <p align="center">
    <img src="https://github.com/user-attachments/assets/0e47cf2e-f64a-41eb-8be5-2e88e0314186" alt="Logo" width="254" />
    <br />
    Winterm
  </p>
</h1>

A terminal for Windows.

- Native
- Small (less than a megabyte)
- Fast (rendered on the GPU)

# Status

The renderer is pretty much done, the terminal part is pretty basic/crashy at the moment.

<p align="center">
  <img src="https://github.com/user-attachments/assets/bd567ad1-2bf0-4404-ab50-be18c2880cbe" />
</p>

## Custom shaders.

winterm uses Direct3D11 and has a command-line option to override the shader.  Here's an example of what you can do with just a few lines of shader code:

<p align="center">
  <img src="https://github.com/user-attachments/assets/88022a63-f85d-4627-8ae0-f578361fc52f" />
</p>



# Acknowledgements

This project was inspired by Casey Muratori's refterm, which provided valuable architectural insights and reference implementation.

This project also leverages libGhostty, thanks to Mitchell and the Ghostty community for their work.
