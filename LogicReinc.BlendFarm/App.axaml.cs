using System;
using Avalonia;
using Avalonia.Controls.ApplicationLifetimes;
using Avalonia.Markup.Xaml;
using LogicReinc.BlendFarm.Windows;

namespace LogicReinc.BlendFarm
{
    public partial class App : Application
    {
        public override void Initialize()
        {
            try
            {
                AvaloniaXamlLoader.Load(this);
            }
            catch (Exception ex)
            {
                ExceptionLogger.LogException("XAML LOADING ERROR", ex);
                throw;
            }
        }

        public override void OnFrameworkInitializationCompleted()
        {
            try
            {
                if (ApplicationLifetime is IClassicDesktopStyleApplicationLifetime desktop)
                {
                    desktop.MainWindow = new ProjectWindow();
                }

                base.OnFrameworkInitializationCompleted();
            }
            catch (Exception ex)
            {
                ExceptionLogger.LogException("FRAMEWORK INITIALIZATION ERROR", ex);
                throw;
            }
        }
    }
}
