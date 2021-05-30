module Interface.IVideoOut;

public interface IVideoOut {
    public void destroy();
    public void renderFrame(const ushort[] buffer);
    public void setWindowTitle(string title);
    @property public bool vsync();
}
