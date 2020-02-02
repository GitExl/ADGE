module Interface.ISystemTimer;


public interface ISystemTimer {
    public void start();
    public ulong stop();
    public void wait(const ulong delay);
    public ulong getCounter();
}
