using Azure.Storage.Queues;
using Contoso.Expenses.Common.Models;
using Contoso.Expenses.Web.Models;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.RazorPages;
using Microsoft.Extensions.Options;
using Newtonsoft.Json;
using System;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Threading.Tasks;

namespace Contoso.Expenses.Web.Pages.Expenses
{
    public class CreateModel : PageModel
    {
        private readonly ContosoExpensesWebContext _context;
        private string costCenterAPIUrl;
        private readonly QueueInfo _queueInfo;
        private readonly IWebHostEnvironment _env;

        public CreateModel(ContosoExpensesWebContext context, IOptions<ConfigValues> config, QueueInfo queueInfo,
                            IWebHostEnvironment env)
        {
            _context = context;
            costCenterAPIUrl = config.Value.CostCenterAPIUrl;
            _queueInfo = queueInfo;
            _env = env;
        }


        public IActionResult OnGet()
        {
            return Page();
        }

        [BindProperty]
        public Expense Expense { get; set; }

        public async Task<IActionResult> OnPostAsync()
        {
            if (!ModelState.IsValid)
            {
                return Page();
            }

            // Look up cost center
            CostCenter costCenter = await GetCostCenterAsync(costCenterAPIUrl, Expense.SubmitterEmail);
            if (costCenter != null)
            {
                Expense.CostCenter = costCenter.CostCenterName;
                Expense.ApproverEmail = costCenter.ApproverEmail;
            }
            else
            {
                Expense.CostCenter = "Unkown";
                Expense.ApproverEmail = "Unknown";
            }

            // Write to DB, but don't wait right now
            _context.Expense.Add(Expense);
            Task t = _context.SaveChangesAsync();

            // Serialize the expense and write it to the Azure Storage Queue
            QueueClient queueClient = new QueueClient(_queueInfo.ConnectionString, _queueInfo.QueueName, new QueueClientOptions
            {
                MessageEncoding = QueueMessageEncoding.Base64
            });

            await queueClient.CreateIfNotExistsAsync();
            await queueClient.SendMessageAsync(JsonConvert.SerializeObject(Expense));

            // Ensure the DB write is complete
            t.Wait();

            return RedirectToPage("./Index");
        }

        private static async Task<CostCenter> GetCostCenterAsync(string apiBaseURL, string email)
        {
            string requestUri = "api/costcenter" + "/" + email;

            using (HttpClient client = new HttpClient())
            {
                client.BaseAddress = new Uri(apiBaseURL);
                client.DefaultRequestHeaders.Accept.Clear();
                client.DefaultRequestHeaders.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));

                HttpResponseMessage httpResponse = await client.GetAsync(requestUri);

                if (httpResponse.IsSuccessStatusCode)
                {
                    string response = await httpResponse.Content.ReadAsStringAsync();
                    CostCenter costCenter = JsonConvert.DeserializeObject<CostCenter>(response);
                    if (costCenter != null)
                    {
                        Console.WriteLine("SubmitterEmail: {0} \r\n ApproverEmail: {1} \r\n CostCenterName: {2}",
                            costCenter.SubmitterEmail, costCenter.ApproverEmail, costCenter.CostCenterName);
                    }

                    return costCenter;
                }
                else
                {
                    Console.WriteLine("Internal server error: " + httpResponse.StatusCode);
                    return null;
                }
            }
        }
    }
}